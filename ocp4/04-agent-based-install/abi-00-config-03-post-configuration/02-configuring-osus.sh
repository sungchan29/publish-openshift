#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

###
### Updating a cluster in a disconnected environment using the OpenShift Update Service
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#updating-disconnected-cluster-osus
###
if [[ -z "$CLUSTER_OSUS_CRT_FILE" ]]; then
    if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
        echo "[INFO] Custom CA and Ingress TLS certificate files found."
    else
        echo "[ERROR] One or more required certificate files are missing:"
        [[ ! -f "$CUSTOM_ROOT_CA_FILE" ]] && echo "  - Custom Root CA file not found: '$CUSTOM_ROOT_CA_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_KEY_FILE" ]] && echo "  - Ingress TLS Key file not found: '$INGRESS_CUSTOM_TLS_KEY_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]] && echo "  - Ingress TLS Certificate file not found: '$INGRESS_CUSTOM_TLS_CRT_FILE'"
        exit 1
    fi
fi

if [[ -z "$OSUS_POLICY_ENGINE_GRAPH_URI" ]]; then
    CLUSTER_OSUS_CRT_FILE="${CLUSTER_OSUS_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"
    ### 1. Image registry CA config map for the update service
    ./oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  updateservice-registry: | 
$(sed 's/^/    /' "$CLUSTER_OSUS_CRT_FILE")
  ${MIRROR_REGISTRY_HOSTNAME}..${MIRROR_REGISTRY_PORT}: | 
$(sed 's/^/    /' "$MIRROR_REGISTRY_CRT_FILE")
EOF

    ### 2. Update the cluster-wide proxy configuration with the newly created config map
    ### https://access.redhat.com/solutions/7040684
    ./oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF

    ### 3. Installing the OpenShift Update Service Operator
    ### 3.1. Create a namespace for the OpenShift Update Service Operator: 
    ./oc create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-update-service
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

    ### 3.2. Install the OpenShift Update Service Operator by creating the following objects
    ./oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: openshift-update-service
spec:
  targetNamespaces:
  - openshift-update-service
EOF

    ### 3.3. Create a Subscription object
    ocp_major_minor="$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)"
    catalog_source=$(./oc -n openshift-marketplace get catalogsources -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "redhat-operator-index:v${ocp_major_minor}" | awk '{print $1}')
    ./oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: openshift-update-service
spec:
  channel: v1
  installPlanApproval: "Automatic"
  source: "$catalog_source" 
  sourceNamespace: "openshift-marketplace"
  name: "cincinnati-operator"
EOF

    cincinnati_sub_state=""
    for ((i=1; i<=300; i++)); do
        sleep 2
        
        if [[ "$cincinnati_sub_state" != "AtLatestKnown" ]]; then
            ### Retrieve Subscription status for updateservice-operator
            cincinnati_sub_state=$(./oc -n openshift-update-service get subscription update-service-subscription -o jsonpath='{range .items[*]}{.status.state}{"\n"}' 2>/dev/null)
            if [[ "$cincinnati_sub_state" != "AtLatestKnown" ]]; then
                echo "[INFO] Waiting for Subscription to be ready, current state: ${cincinnati_sub_state:-unknown}"
            fi
        else
            echo "./oc -n openshift-update-service get subscription update-service-subscription"
            ./oc -n openshift-update-service get subscription update-service-subscription
            echo ""

            ### Retrieve the status of pods with label name=updateservice-operator in the openshift-update-service namespace
            pod_status=$(./oc -n openshift-update-service get pods -l name=updateservice-operator -o jsonpath='{.items[*].status.phase}')

            ### Check if no pods are found or if the status is not Running
            if [ -z "$pod_status" ]; then
                echo "[INFO] No pods found with label name=updateservice-operator in namespace openshift-update-service"
            elif [ "$pod_status" != "Running" ]; then
                echo "[INFO] Pod status is not Running, current status: $pod_status"
            else
                echo "[INFO] Success: updateservice-operator pod is Running"
                break
            fi
        fi
    done

    if [[ "$pod_status" == "Running" ]]; then
        echo "./oc -n openshift-update-service get pods -l name=updateservice-operator"
        ./oc -n openshift-update-service get pods -l name=updateservice-operator
        echo ""

        ### 3.4. Create an OpenShift Update Service application object
        ./oc create -f - <<EOF
apiVersion: updateservice.operator.openshift.io/v1
kind: UpdateService
metadata:
  name: service
  namespace: openshift-update-service
spec:
  replicas: 2
  releases: $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images
  graphDataImage: $MIRROR_REGISTRY/openshift/graph-data:latest
EOF
        for ((i=1; i<=300; i++)); do
            POLICY_ENGINE_GRAPH_URI="$(./oc -n openshift-update-service get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph{"\n"}' updateservice service)"
            SCHEME="${POLICY_ENGINE_GRAPH_URI%%:*}"
            if test "${SCHEME}" = http -o "${SCHEME}" = https; then
                OSUS_POLICY_ENGINE_GRAPH_URI="$POLICY_ENGINE_GRAPH_URI"
                break
            else
                echo -n "."
            fi
            sleep 2
        done
        echo ""
        if test "${SCHEME}" = http -o "${SCHEME}" = https; then
            OSUS_POLICY_ENGINE_GRAPH_URI="$POLICY_ENGINE_GRAPH_URI"
            echo "POLICY_ENGINE_GRAPH_URI : $POLICY_ENGINE_GRAPH_URI"
        else
            echo "[ERROR] Checking installation status of updateservice-operator in namespace openshift-update-service"
        fi
    else
        echo "[ERROR] Checking installation status of updateservice-operator in namespace openshift-update-service"
    fi
fi

###
### Configuring the Cluster Version Operator (CVO)
###
echo "OSUS_POLICY_ENGINE_GRAPH_URI : $OSUS_POLICY_ENGINE_GRAPH_URI"
if [[ -n "$OSUS_POLICY_ENGINE_GRAPH_URI" ]]; then
    PATCH="{\"spec\":{\"upstream\":\"${OSUS_POLICY_ENGINE_GRAPH_URI}\"}}"
    ./oc patch clusterversion version -p $PATCH --type merge
fi
