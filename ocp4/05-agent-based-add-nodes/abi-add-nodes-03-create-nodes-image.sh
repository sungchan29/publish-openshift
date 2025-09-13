#!/bin/bash

### ---------------------------------------------------------------------------------
### Create Add-Nodes ISO Image
### ---------------------------------------------------------------------------------
### This script logs into an existing OpenShift cluster, extracts the necessary
### credentials and certificates, and then uses 'oc adm node-image create' to
### generate a bootable ISO for adding new nodes.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Validate Environment and Setup
### ---------------------------------------------------------------------------------
### Validate that critical environment variables from the config are set.
printf "%-8s%-80s\n" "[INFO]" "=== Validating prerequisites ==="
### Validate that the 'oc' client is available and executable.
if ! command -v ./oc >/dev/null 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "    The './oc' command was not found. Please ensure it is in the current directory. Exiting..."
    exit 1
fi
if ! ./oc version --client >/dev/null 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "    The './oc' binary is not executable. Exiting..."
    exit 1
fi
printf "%-8s%-80s\n" "[INFO]" "    'oc' binary is present and executable."

### Validate that critical variables from the configuration are set.
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN"  "$BASE_DOMAIN"
validate_non_empty "API_SERVER"   "$API_SERVER"

iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_nodes.x86_64.iso"

### ---------------------------------------------------------------------------------
### ISO Creation Function
### ---------------------------------------------------------------------------------
### Defines the main function to generate the node ISO image.
create_node_image() {
     local ca_config=""

    ### Extract the current cluster's pull secret and trusted CA bundle for the new ISO.
    printf "%-8s%-80s\n" "[INFO]" "--- Extracting pull secret and CA bundle from the cluster..."
    oc -n openshift-config get cm user-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' > user-ca-bundle.crt
    oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > pull-secret.txt

    ### Determine whether to use the cluster's CA or proceed insecurely.
    if [[ -f "user-ca-bundle.crt" ]]; then
        ca_config="--certificate-authority=user-ca-bundle.crt"
    else
        ca_config="--insecure"
    fi

    ### Clean up any existing ISO file from a previous run.
    if [[ -f "$iso_file" ]]; then
        printf "%-8s%-80s\n" "[WARN]" "--- Existing nodes ISO file '$iso_file' found. Removing it..."
        rm -f "$iso_file"
    fi

    ### Copy the generated nodes-config.yaml to the current directory where 'oc' will use it.
    cp -f "./$CLUSTER_NAME/add-nodes/nodes-config.yaml" ./

    ### Build and execute the 'oc adm node-image create' command.
    local node_image_create_cmd=(
        "./oc adm node-image create"
        "--registry-config=pull-secret.txt"
        "$ca_config"
        "--output-name=$iso_file"
    )

    local node_image_create_cmd_string="${node_image_create_cmd[*]}"
    printf "%-8s%-80s\n" "[INFO]" "--- Generating nodes ISO with command: $node_image_create_cmd_string"
    if ! eval "$node_image_create_cmd_string"; then
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to create the nodes ISO image. Exiting..."
        exit 1
    fi
}

### ---------------------------------------------------------------------------------
### Main Execution
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Add-Nodes ISO Creation for cluster: $CLUSTER_NAME.$BASE_DOMAIN ==="

### Log into the cluster to perform administrative actions.
login_to_cluster

### Generate the node image.
create_node_image

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### List the contents of the working directory to show the generated files.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Verifying generated files ==="
printf "%-8s%-80s\n" "[INFO]" "--- The bootable ISO is ready for installation:"
ls -lh "$iso_file" || {
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to list the ISO file '$iso_file'. Check if it was created successfully. Exiting..."
}
echo ""