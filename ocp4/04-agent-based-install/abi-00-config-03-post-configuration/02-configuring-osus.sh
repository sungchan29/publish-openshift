#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure OpenShift Update Service (OSUS)
### ---------------------------------------------------------------------------------
### Reference:
### - Updating a cluster in a disconnected environment using the OpenShift Update Service
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index#update-service-create-service-cli_updating-disconnected-cluster-osus
###
### This script installs and configures the OpenShift Update Service (OSUS).
### It uses the confirmed package name 'cincinnati-operator'.

### Enable strict mode.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Path & Config Loading
### ---------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
config_file="${ROOT_DIR}/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Config not found: $config_file"
    exit 1
fi
source "$config_file"

### OC Command Check
if [[ -f "${ROOT_DIR}/oc" ]]; then
    OC_CMD="${ROOT_DIR}/oc"
elif command -v oc &> /dev/null; then
    OC_CMD="oc"
else
    printf "%-12s%-80s\n" "[ERROR]" "'oc' binary not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Main Execution Logic
### ---------------------------------------------------------------------------------

### Check if OSUS URI is already configured in the config file
if [[ -n "${OSUS_POLICY_ENGINE_GRAPH_URI:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "OSUS Graph URI is found in configuration:"
    printf "%-12s%-80s\n" "[INFO]" "    > $OSUS_POLICY_ENGINE_GRAPH_URI"
    printf "%-12s%-80s\n" "[INFO]" "Skipping OSUS installation steps. Proceeding to CVO configuration."

else
    ### =========================================================================
    ### OSUS INSTALLATION BLOCK (Runs if URI is NOT set)
    ### =========================================================================
    printf "%-12s%-80s\n" "[INFO]" "OSUS_POLICY_ENGINE_GRAPH_URI is not set. Proceeding with Local OSUS Installation..."

    ### Step 0: Validate Required Variables for Installation
    MISSING_VARS=0
    [[ -z "${MIRROR_REGISTRY:-}" ]]          && { printf "%-12s%-80s\n" "[ERROR]" "Variable 'MIRROR_REGISTRY' is missing."; MISSING_VARS=1; }
    [[ -z "${LOCAL_REPOSITORY_NAME:-}" ]]    && { printf "%-12s%-80s\n" "[ERROR]" "Variable 'LOCAL_REPOSITORY_NAME' is missing."; MISSING_VARS=1; }
    [[ -z "${OCP_VERSION:-}" ]]              && { printf "%-12s%-80s\n" "[ERROR]" "Variable 'OCP_VERSION' is missing."; MISSING_VARS=1; }

    if [[ "$MISSING_VARS" -eq 1 ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "Installation cannot proceed. Please check '$config_file'."
        exit 1
    fi

    ### Step 1: Validate Prerequisites (Certificates)
    printf "%-12s%-80s\n" "[INFO]" "Validating Certificate Files..."

    CLUSTER_OSUS_CRT_FILE="${CLUSTER_OSUS_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"
    MIRROR_REGISTRY_CRT_FILE="${MIRROR_REGISTRY_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"

    if [[ ! -f "$CLUSTER_OSUS_CRT_FILE" || ! -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "One or more required certificate files are missing."
        exit 1
    fi

    ### Step 2: Configure Cluster-wide Trust for Mirror Registry
    printf "%-12s%-80s\n" "[INFO]" "Configuring Cluster-wide Trust for Mirror Registry..."

    REGISTRY_PEM=$(sed 's/^/    /' "$CLUSTER_OSUS_CRT_FILE")
    MIRROR_PEM=$(sed 's/^/    /' "$MIRROR_REGISTRY_CRT_FILE")

    CM_YAML="apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  updateservice-registry: |
$REGISTRY_PEM
  ${MIRROR_REGISTRY_HOSTNAME}..${MIRROR_REGISTRY_PORT}: |
$MIRROR_PEM"

    printf "%-12s%-80s\n" "[INFO]" "-- Injecting CA certificate into 'openshift-config/mirror-registry-ca'..."

    CMD_STR="echo \"\$CM_YAML\" | $OC_CMD apply -f -"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        echo \"(ConfigMap YAML content)\" | $OC_CMD apply -f -"
    echo "$CM_YAML" | $OC_CMD apply -f -

    ### Patch Image Config
    printf "%-12s%-80s\n" "[INFO]" "-- Patching cluster-wide Image configuration..."
    IMAGE_PATCH='{"spec":{"additionalTrustedCA":{"name":"mirror-registry-ca"}}}'
    CMD_STR="$OC_CMD patch image.config.openshift.io/cluster --type=merge --patch '$IMAGE_PATCH'"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    $OC_CMD patch image.config.openshift.io/cluster --type=merge --patch "$IMAGE_PATCH"


    ### Step 3: Install the OpenShift Update Service Operator
    printf "%-12s%-80s\n" "[INFO]" "Installing OpenShift Update Service Operator..."

    ### 3-1. Create Namespace
    printf "%-12s%-80s\n" "[INFO]" "-- Creating Namespace 'openshift-update-service'..."
    CMD_STR="$OC_CMD create namespace openshift-update-service --dry-run=client -o yaml | $OC_CMD apply -f -"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    eval "$CMD_STR"

    ### 3-2. Create OperatorGroup
    printf "%-12s%-80s\n" "[INFO]" "-- Creating OperatorGroup..."
    OG_YAML="apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: openshift-update-service
spec:
  targetNamespaces:
  - openshift-update-service"

    CMD_STR="echo \"\$OG_YAML\" | $OC_CMD apply -f -"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        echo \"(OperatorGroup YAML)\" | $OC_CMD apply -f -"
    echo "$OG_YAML" | $OC_CMD apply -f -

    ### 3-3. Create Subscription (Verified Package Name: cincinnati-operator)
    printf "%-12s%-80s\n" "[INFO]" "-- Creating Subscription..."

    ocp_major_minor="$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)"

    ### 1. Find CatalogSource
    ### Finds catalog source containing 'redhat-operator-index' in name or image
    catalog_source=$($OC_CMD -n openshift-marketplace get catalogsources -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "redhat-operator-index:v${ocp_major_minor}" | awk '{print $1}')

    if [[ -z "$catalog_source" ]]; then
        ### Fallback: Find any 'redhat-operator' catalog source name
        catalog_source=$($OC_CMD -n openshift-marketplace get catalogsources -o name | grep "redhat-operator" | head -n 1 | cut -d/ -f2)
    fi

    if [[ -z "$catalog_source" ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "Could not find a suitable Red Hat Operator catalog source. Exiting..."
        exit 1
    fi
    printf "%-12s%-80s\n" "[INFO]" "    > Using CatalogSource: $catalog_source"

    ### 2. Package Verification (cincinnati-operator)
    TARGET_PACKAGE="cincinnati-operator"

    printf "%-12s%-80s\n" "[INFO]" "    > Verifying package '$TARGET_PACKAGE' in catalog..."

    if $OC_CMD get packagemanifests -n openshift-marketplace -l catalog="$catalog_source" -o name | grep -q "$TARGET_PACKAGE"; then
        printf "%-12s%-80s\n" "[INFO]" "      Confirmed package found: $TARGET_PACKAGE"
    else
        printf "%-12s%-80s\n" "[ERROR]" "Package '$TARGET_PACKAGE' not found in catalog '$catalog_source'."
        printf "%-12s%-80s\n" "[INFO]" "      Debug: Listing top 5 packages in catalog:"
        $OC_CMD get packagemanifests -n openshift-marketplace -l catalog="$catalog_source" --no-headers | head -n 5 | awk '{print "      - " $1}'
        exit 1
    fi

    ### 3. Create Subscription
    SUB_YAML="apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: openshift-update-service
spec:
  channel: v1
  installPlanApproval: Automatic
  source: $catalog_source
  sourceNamespace: openshift-marketplace
  name: $TARGET_PACKAGE"

    CMD_STR="echo \"\$SUB_YAML\" | $OC_CMD apply -f -"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        echo \"(Subscription YAML)\" | $OC_CMD apply -f -"
    echo "$SUB_YAML" | $OC_CMD apply -f -


    ### Step 4: Wait for Operator Installation
    printf "%-12s%-80s\n" "[INFO]" "Waiting for Operator installation..."

    CSV_NAME=""
    ### Wait loop to get the CSV name from the Subscription status
    for ((i=1; i<=60; i++)); do
        ### Query Subscription for installedCSV
        CSV_NAME=$($OC_CMD -n openshift-update-service get subscription update-service-subscription -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)

        if [[ -n "$CSV_NAME" ]]; then
            printf "\n%-12s%-80s\n" "[INFO]" "    > Found CSV: $CSV_NAME"
            break
        fi

        printf "\r%-12s%-80s" "[INFO]" "    > Waiting for CSV creation... ($i/60)"
        sleep 5
    done

    if [[ -z "$CSV_NAME" ]]; then
        printf "\n%-12s%-80s\n" "[ERROR]" "Timed out waiting for CSV creation."
        exit 1
    fi

    ### Wait for CSV Succeeded
    printf "%-12s%-80s\n" "[INFO]" "-- Waiting for CSV '$CSV_NAME' to succeed..."
    CMD_STR="$OC_CMD -n openshift-update-service wait csv \"$CSV_NAME\" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    eval "$CMD_STR"

    ### Wait for Pod Ready
    printf "%-12s%-80s\n" "[INFO]" "-- Waiting for 'updateservice-operator' pod..."
    CMD_STR="$OC_CMD -n openshift-update-service wait pod -l name=updateservice-operator --for=condition=Ready --timeout=300s"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    eval "$CMD_STR"


    ### Step 5: Deploy Update Service Instance
    printf "%-12s%-80s\n" "[INFO]" "Deploying Update Service Instance..."

    SVC_YAML="apiVersion: updateservice.operator.openshift.io/v1
kind: UpdateService
metadata:
  name: service
  namespace: openshift-update-service
spec:
  replicas: 2
  releases: $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images
  graphDataImage: $MIRROR_REGISTRY/openshift/graph-data:latest"

    CMD_STR="echo \"\$SVC_YAML\" | $OC_CMD apply -f -"
    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        echo \"(UpdateService YAML)\" | $OC_CMD apply -f -"
    echo "$SVC_YAML" | $OC_CMD apply -f -


    ### Step 6: Wait for Policy Engine URI
    printf "%-12s%-80s\n" "[INFO]" "Waiting for Policy Engine URI..."

    for ((i=1; i<=300; i++)); do
        URI=$($OC_CMD -n openshift-update-service get updateservice service -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' 2>/dev/null || true)

        if [[ "$URI" == http* ]]; then
            OSUS_POLICY_ENGINE_GRAPH_URI="$URI"
            printf "\n%-12s%-80s\n" "[INFO]" "    > Success: $OSUS_POLICY_ENGINE_GRAPH_URI"
            break
        fi
        printf "\r%-12s%-80s" "[INFO]" "    > Waiting for endpoint... ($i/300)"
        sleep 2
    done

    if [[ -z "${OSUS_POLICY_ENGINE_GRAPH_URI:-}" ]]; then
        printf "\n%-12s%-80s\n" "[ERROR]" "Timed out waiting for Policy Engine URI."
        exit 1
    fi
fi


### Step 7: Configure CVO
printf "%-12s%-80s\n" "[INFO]" "Configuring Cluster Version Operator (CVO)..."

if [[ -n "${OSUS_POLICY_ENGINE_GRAPH_URI:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "-- Patching CVO to use URI: $OSUS_POLICY_ENGINE_GRAPH_URI"

    CVO_PATCH="{\"spec\":{\"upstream\":\"${OSUS_POLICY_ENGINE_GRAPH_URI}\"}}"
    CMD_STR="$OC_CMD patch clusterversion version -p '$CVO_PATCH' --type merge"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    $OC_CMD patch clusterversion version -p "$CVO_PATCH" --type merge

    printf "%-12s%-80s\n" "[INFO]" "SUCCESS: OpenShift Update Service configured."
else
    printf "%-12s%-80s\n" "[ERROR]" "OSUS_POLICY_ENGINE_GRAPH_URI is not set. CVO patching failed."
    exit 1
fi