#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure OpenShift Update Service (OSUS)
### ---------------------------------------------------------------------------------
### This script automates the installation and configuration of the OpenShift
### Update Service to enable updates in a disconnected environment.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Validate Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration file to load all necessary variables.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

###
### Updating a cluster in a disconnected environment using the OpenShift Update Service
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#updating-disconnected-cluster-osus
###
### Validate certificate files if a disconnected update service is being configured.
if [[ -z "$OSUS_POLICY_ENGINE_GRAPH_URI" ]]; then
    echo "INFO: OSUS_POLICY_ENGINE_GRAPH_URI is not set. Proceeding with local Update Service setup."
    if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
        echo "INFO: Found required certificate files for local Update Service."
    else
        echo "ERROR: One or more required certificate files for a disconnected update service are missing:"
        [[ ! -f "$CUSTOM_ROOT_CA_FILE" ]] && echo "  - Custom Root CA file not found: '$CUSTOM_ROOT_CA_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_KEY_FILE" ]] && echo "  - Ingress TLS Key file not found: '$INGRESS_CUSTOM_TLS_KEY_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]] && echo "  - Ingress TLS Certificate file not found: '$INGRESS_CUSTOM_TLS_CRT_FILE'"
        exit 1
    fi
fi

### ---------------------------------------------------------------------------------
### Install and Configure OpenShift Update Service
### ---------------------------------------------------------------------------------
if [[ -z "$OSUS_POLICY_ENGINE_GRAPH_URI" ]]; then
    CLUSTER_OSUS_CRT_FILE="${CLUSTER_OSUS_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"

    ### 1. Create a ConfigMap for the mirror registry's trusted CA.
    echo "INFO: Creating ConfigMap 'mirror-registry-ca' in openshift-config..."
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
    echo "INFO: ConfigMap 'mirror-registry-ca' created successfully."

    ### 2. Update the cluster-wide image configuration to trust the new ConfigMap.
    echo "INFO: Patching cluster-wide Image configuration to trust the mirror registry CA..."
    ./oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF
    echo "INFO: Cluster-wide image configuration updated."

    ### 3. Install the OpenShift Update Service Operator.
    echo "INFO: Installing OpenShift Update Service Operator..."
    echo "INFO: -> Creating 'openshift-update-service' namespace..."
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
    echo "INFO: -> Namespace created."

    echo "INFO: -> Creating 'update-service-operator-group'..."
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
    echo "INFO: -> OperatorGroup created."

    echo "INFO: -> Creating Subscription for 'cincinnati-operator'..."
    ocp_major_minor="$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)"
    catalog_source=$(./oc -n openshift-marketplace get catalogsources -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "redhat-operator-index:v${ocp_major_minor}" | awk '{print $1}')
    if [[ -z "$catalog_source" ]]; then
        echo "ERROR: Could not find a suitable catalog source for OpenShift version '$ocp_major_minor'. Please check your mirror configuration." >&2
        exit 1
    fi
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
    echo "INFO: -> Subscription created. Waiting for operator to be ready..."

    ### Wait for the operator pod to become Running.
    cincinnati_sub_state=""
    pod_status=""
    for ((i=1; i<=300; i++)); do
        sleep 2
        
        cincinnati_sub_state=$(./oc -n openshift-update-service get subscription update-service-subscription -o jsonpath='{.status.state}' 2>/dev/null)
        if [[ "$cincinnati_sub_state" != "AtLatestKnown" ]]; then
            echo "INFO: Waiting for Subscription to be ready. Current state: ${cincinnati_sub_state:-unknown}. Attempt $i of 300."
            continue
        fi

        pod_status=$(./oc -n openshift-update-service get pods -l name=updateservice-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
        if [[ -z "$pod_status" ]]; then
            echo "INFO: No operator pods found yet. Attempt $i of 300."
        elif [[ "$pod_status" != "Running" ]]; then
            echo "INFO: Operator pod status is not Running. Current status: '$pod_status'. Attempt $i of 300."
        else
            echo "INFO: Success: updateservice-operator pod is Running."
            break
        fi
    done

    if [[ "$pod_status" != "Running" ]]; then
        echo "ERROR: Updateservice operator pod did not reach a 'Running' state within the timeout period." >&2
        exit 1
    fi

    echo "INFO: Operator installation complete. Creating UpdateService application object..."
    
    ### 4. Create the UpdateService application object.
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
    echo "INFO: UpdateService application object created. Waiting for Policy Engine URI..."

    ### Wait for the Policy Engine URI to be available.
    POLICY_ENGINE_GRAPH_URI=""
    for ((i=1; i<=300; i++)); do
        sleep 2
        POLICY_ENGINE_GRAPH_URI="$(./oc -n openshift-update-service get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' updateservice service 2>/dev/null)"
        SCHEME="${POLICY_ENGINE_GRAPH_URI%%:*}"
        if test "${SCHEME}" = http -o "${SCHEME}" = https; then
            OSUS_POLICY_ENGINE_GRAPH_URI="$POLICY_ENGINE_GRAPH_URI"
            echo "INFO: Policy Engine URI obtained: $OSUS_POLICY_ENGINE_GRAPH_URI"
            break
        fi
        echo -n "."
    done
    echo ""
    if test "${SCHEME}" != http -a "${SCHEME}" != https; then
        echo "ERROR: Failed to retrieve the Policy Engine URI within the timeout period." >&2
        exit 1
    fi
fi

### ---------------------------------------------------------------------------------
### Configure the Cluster Version Operator (CVO)
### ---------------------------------------------------------------------------------
### Patch the CVO to point to the new Update Service.
echo "INFO: Patching Cluster Version Operator (CVO) to use the new Update Service URI..."
if [[ -n "$OSUS_POLICY_ENGINE_GRAPH_URI" ]]; then
    PATCH="{\"spec\":{\"upstream\":\"${OSUS_POLICY_ENGINE_GRAPH_URI}\"}}"
    ./oc patch clusterversion version -p "$PATCH" --type merge
    echo "INFO: CVO successfully patched. Cluster update checks are now redirected to the local Update Service."
else
    echo "INFO: OSUS_POLICY_ENGINE_GRAPH_URI was not set. CVO was not patched."
fi