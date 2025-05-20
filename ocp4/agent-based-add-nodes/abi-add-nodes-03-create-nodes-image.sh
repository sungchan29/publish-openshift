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
validate_domain    "BASE_DOMAIN"  "$BASE_DOMAIN" "cluster configuration"
validate_non_empty "API_SERVER"   "$API_SERVER"
validate_file      "$PULL_SECRET"

if [[ -n "$CUSTOM_ROOT_CA" ]]; then
    validate_file "$CUSTOM_ROOT_CA"
fi

### Create node image
create_node_image() {
    local iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_nodes.x86_64.iso"
    local registry_config=""
    local ca_config=""

    ### Prepare registry configuration
    registry_config="$PULL_SECRET"
    echo "[INFO] Using pull secret: $registry_config"

    ### Prepare custom CA if provided
    if [[ -n "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
        ca_config="--certificate-authority=$MIRROR_REGISTRY_TRUST_FILE"
        echo "[INFO] Using custom root CA: $MIRROR_REGISTRY_TRUST_FILE"
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
        "--registry-config='$registry_config'"
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