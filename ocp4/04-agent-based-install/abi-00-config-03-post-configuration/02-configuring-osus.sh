#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure OpenShift Update Service (OSUS)
### ---------------------------------------------------------------------------------
### Reference:
### - Updating a cluster in a disconnected environment using the OpenShift Update Service
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment#updating-disconnected-cluster-osus
###
### This script installs and configures the OpenShift Update Service (OSUS) to enable cluster updates in a disconnected environment.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Install and Configure OpenShift Update Service
### ---------------------------------------------------------------------------------
### This entire block is skipped if OSUS is already configured.
if [[ -z "${OSUS_POLICY_ENGINE_GRAPH_URI:-}" ]]; then
    ### Step 1/5: Validate Prerequisites for local OSUS setup
    printf "%-12s%-80s\n" "[INFO]" "Validating Prerequisites for OSUS Setup ..."
    if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" && -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
        echo -n ""
    else
        printf "%-12s%-80s\n" "[ERROR]" "One or more required certificate files are missing. Exiting..."
        [[ ! -f "$CUSTOM_ROOT_CA_FILE" ]]         && printf "%-12s%-80s\n" "[ERROR]" "- Custom Root CA file not found: '$CUSTOM_ROOT_CA_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_KEY_FILE" ]] && printf "%-12s%-80s\n" "[ERROR]" "- Ingress TLS Key file not found: '$INGRESS_CUSTOM_TLS_KEY_FILE'"
        [[ ! -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]] && printf "%-12s%-80s\n" "[ERROR]" "- Ingress TLS Cert file not found: '$INGRESS_CUSTOM_TLS_CRT_FILE'"
        [[ ! -f "$MIRROR_REGISTRY_CRT_FILE" ]]    && printf "%-12s%-80s\n" "[ERROR]" "- Mirror Registry Cert file not found: '$MIRROR_REGISTRY_CRT_FILE'"
        exit 1
    fi
    CLUSTER_OSUS_CRT_FILE="${CLUSTER_OSUS_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"
    ### Step 2/5: Configure Cluster-wide Trust for Mirror Registry
    printf "%-12s%-80s\n" "[INFO]" "Configuring Cluster-wide Trust for Mirror Registry ..."
    printf "%-12s%-80s\n" "[INFO]" "-- Creating ConfigMap to provide mirror registry's CA..."
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
    printf "%-12s%-80s\n" "[INFO]" "-- Patching cluster-wide Image configuration to use the trusted CA..."
    ./oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF
    ### Step 3/5: Install the OpenShift Update Service Operator
    printf "%-12s%-80s\n" "[INFO]" "Installing the OpenShift Update Service Operator ..."
    printf "%-12s%-80s\n" "[INFO]" "-- Creating 'openshift-update-service' namespace..."
    # Using 'apply' for idempotency
    ./oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-update-service
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
    printf "%-12s%-80s\n" "[INFO]" "-- Creating 'update-service-operator-group'..."
    ./oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: openshift-update-service
spec:
  targetNamespaces:
  - openshift-update-service
EOF
    printf "%-12s%-80s\n" "[INFO]" "-- Creating Subscription for 'cincinnati-operator'..."
    ocp_major_minor="$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)"
    catalog_source=$(./oc -n openshift-marketplace get catalogsources -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "redhat-operator-index:v${ocp_major_minor}" | awk '{print $1}')
    if [[ -z "$catalog_source" ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "   Could not find a suitable Red Hat Operator catalog source for OpenShift v$ocp_major_minor. Exiting..."
        exit 1
    fi
    ./oc apply -f - <<EOF
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

    ### --- Robust Wait Logic --- ###
    # This section is improved to be more robust.
    # First, wait for the ClusterServiceVersion (CSV) to appear and succeed,
    # which indicates the operator has been installed correctly by OLM.
    
    CSV_NAME=""
    printf "%-12s%-80s\n" "[INFO]" "   -- Waiting for the Operator's CSV to be installed..."
    ### Wait up to 5 minutes for the CSV to be created by the subscription.
    for ((i=1; i<=60; i++)); do
        ### Get the name of the CSV created for the 'cincinnati-operator'
        CSV_NAME=$(./oc -n openshift-update-service get csv -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Update Service")].metadata.name}' 2>/dev/null)
        if [[ -n "$CSV_NAME" ]]; then
            printf "\n%-12s%-80s\n" "[INFO]" "      Found CSV: $CSV_NAME. Waiting for it to succeed..."
            break
        fi
        printf "\r%-12s%-80s" "[INFO]" "      - CSV not yet created. Retrying... ($i/60)"
        sleep 5
    done

    if [[ -z "$CSV_NAME" ]]; then
        printf "\n%-12s%-80s\n" "[ERROR]" "      Timed out waiting for the CSV to be created." >&2
        printf "%-12s%-80s\n" ""          "      Please check the subscription status with: oc get sub -n openshift-update-service update-service-subscription -o yaml" >&2
        exit 1
    fi

    ### Now wait for the CSV installation to succeed.
    if ! ./oc -n openshift-update-service wait csv "$CSV_NAME" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s; then
        printf "\n%-12s%-80s\n" "[ERROR]" "The operator CSV '$CSV_NAME' failed to reach 'Succeeded' phase." >&2
        printf "%-12s%-80s\n" ""          "   Please check the CSV status with: oc describe csv $CSV_NAME -n openshift-update-service" >&2
        exit 1
    fi

    printf "%-12s%-80s\n" "[INFO]" "   Success: Operator CSV is ready."
    printf "%-12s%-80s\n" "[INFO]" "   -- Waiting for the updateservice-operator pod to become Ready..."

    ### Now that the CSV is ready, the pod is guaranteed to exist. Wait for it to be Ready.
    if ! ./oc -n openshift-update-service wait pod -l name=updateservice-operator --for=condition=Ready --timeout=300s; then
        printf "\n%-12s%-80s\n" "[ERROR]" "   Failed or timed out waiting for the 'updateservice-operator' pod to become Ready." >&2
        printf "%-12s%-80s\n" ""          "   Please check the pod status with: oc get pods -n openshift-update-service" >&2
        exit 1
    fi
    
    printf "%-12s%-80s\n" "[INFO]" "      Success: updateservice-operator pod is now Ready."

    ### Step 4/5: Deploy the OpenShift Update Service Instance
    printf "%-12s%-80s\n" "[INFO]" "Deploying the OpenShift Update Service Instance ..."
    printf "%-12s%-80s\n" "[INFO]" "-- Creating the 'UpdateService' application object..."
    ./oc apply -f - <<EOF
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
    printf "%-12s%-80s\n" "[INFO]" "   Waiting for the service endpoint (Policy Engine URI) to become available..."
    POLICY_ENGINE_GRAPH_URI=""
    for ((i=1; i<=300; i++)); do
        POLICY_ENGINE_GRAPH_URI="$(./oc -n openshift-update-service get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' updateservice service 2>/dev/null || true)"
        SCHEME="${POLICY_ENGINE_GRAPH_URI%%:*}"

        if [[ "${SCHEME}" == "http" || "${SCHEME}" == "https" ]]; then
            OSUS_POLICY_ENGINE_GRAPH_URI="$POLICY_ENGINE_GRAPH_URI"
            printf "%-12s%-80s\n" "[INFO]" "   Success: Policy Engine URI obtained: $OSUS_POLICY_ENGINE_GRAPH_URI"
            break
        fi
        printf "\r%-12s%-80s" "[INFO]" "   - Attempt $i/300: URI not yet available. Retrying..."
        sleep 2
    done
    
    if [[ "${SCHEME}" != "http" && "${SCHEME}" != "https" ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "   Timed out waiting for the Policy Engine URI. Exiting..."
        exit 1
    fi
fi

### ---------------------------------------------------------------------------------
### Step 5/5: Configure the Cluster Version Operator (CVO)
### ---------------------------------------------------------------------------------
printf "%-12s%-80s\n" "[INFO]" "Configuring the Cluster Version Operator (CVO) ..."
if [[ -n "${OSUS_POLICY_ENGINE_GRAPH_URI:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "-- Patching CVO to use the local OpenShift Update Service..."
    upstream_patch="{\"spec\":{\"upstream\":\"${OSUS_POLICY_ENGINE_GRAPH_URI}\"}}"
    ./oc patch clusterversion version -p "$upstream_patch" --type merge
else
    ### This case should not be reached if the script runs from the beginning,
    ### but it's a good safeguard.
    printf "%-12s%-80s\n" "[ERROR]" "OSUS_POLICY_ENGINE_GRAPH_URI is not set. CVO patching will be skipped."
fi
