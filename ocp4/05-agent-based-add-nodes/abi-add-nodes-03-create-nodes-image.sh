#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Validate oc CLI
if ! command -v ./oc >/dev/null 2>&1; then
    echo "[ERROR] './oc' command not found. Please install OpenShift CLI. Exiting..."
    exit 1
fi
if ! ./oc version --client >/dev/null 2>&1; then
    echo "[ERROR] Extracted oc is not executable. Exiting..."
    exit 1
fi
echo "[INFO] oc binary is executable."

### Validate critical variables and files
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN"  "$BASE_DOMAIN"
validate_non_empty "API_SERVER"   "$API_SERVER"

### Create node image
create_node_image() {
    local iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_nodes.x86_64.iso"
    local registry_config=""
    local ca_config=""

    ### Prepare registry configuration
    oc -n openshift-config get cm user-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' > user-ca-bundle.crt
    oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > pull-secret.txt

    ### Prepare custom CA if provided
    if [[ -f "user-ca-bundle.crt" ]]; then
        ca_config="--certificate-authority=user-ca-bundle.crt"
    else
        ca_config="--insecure"
    fi

    ### Clean up existing ISO
    if [[ -f "$iso_file" ]]; then
        echo "[WARN] Existing ISO file $iso_file will be deleted."
        rm -f "$iso_file"
    fi

    ### Run oc adm node-image create
    cp -f ./$CLUSTER_NAME/add-nodes/nodes-config.yaml ./

    node_image_create_cmd=(
        "./oc adm node-image create"
        "--registry-config=pull-secret.txt"
        "$ca_config"
        "--output-name='$iso_file'"
    )

    node_image_create_cmd_string="${node_image_create_cmd[*]}"
    echo "[INFO] Executing $node_image_create_cmd_string"
    if ! eval "$node_image_create_cmd_string"; then
        echo "[ERROR] Failed to create iso image. Exiting..."
        exit 1
    fi

    echo "[INFO] Node image created successfully: $iso_file"
    ls -lh "$iso_file"
}

### Main logic
echo "[INFO] Starting abi-add-nodes-02-create-nodes-image.sh for cluster: $CLUSTER_NAME.$BASE_DOMAIN"

### Login to cluster
login_to_cluster

### Create node image
create_node_image

echo "[INFO] Script completed successfully."