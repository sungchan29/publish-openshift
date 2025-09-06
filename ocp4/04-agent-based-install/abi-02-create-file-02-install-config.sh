#!/bin/bash

### ---------------------------------------------------------------------------------
### Create Installation Manifests
### ---------------------------------------------------------------------------------
### This script prepares the core 'install-config.yaml' file, which defines
### the cluster's high-level configuration based on your setup.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the main configuration file to load all necessary variables and functions.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' could not be found. Exiting."
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Please check file syntax or permissions."
    exit 1
fi

### Validate critical files before proceeding.
echo "--- Validating prerequisite files..."
validate_file "$PULL_SECRET"

if [[ -z "$(cat "$PULL_SECRET")" ]]; then
    echo "ERROR: The PULL_SECRET file exists but is empty. It must contain your mirror registry credentials."
    exit 1
fi

### Validate pull secret JSON format if 'jq' is available.
if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$PULL_SECRET" >/dev/null 2>&1; then
        echo "ERROR: The PULL_SECRET file is not a valid JSON document. Please correct its format."
        exit 1
    fi
    echo "INFO: PULL_SECRET format validated successfully."
fi

### Check for the existence of the 'agent-config.yaml' file, which is required.
if [[ ! -f "./$CLUSTER_NAME/orig/agent-config.yaml" ]]; then
    echo "ERROR: The required file './$CLUSTER_NAME/orig/agent-config.yaml' was not found."
    echo "INFO: Please run 'abi-02-create-file-01-agent-config.sh' first to generate it."
    exit 1
fi
echo "INFO: All prerequisite files found."

### ---------------------------------------------------------------------------------
### Count Nodes and Create 'install-config.yaml'
### ---------------------------------------------------------------------------------
### Count the number of master and worker nodes from the 'agent-config.yaml' file.
echo "--- Counting nodes from 'agent-config.yaml'..."
master_count=$(grep -E "^\s*role:\s*master\s*$" "./$CLUSTER_NAME/orig/agent-config.yaml" | wc -l || true)
worker_count=$(grep -E "^\s*role:\s*worker\s*$" "./$CLUSTER_NAME/orig/agent-config.yaml" | wc -l || true)
echo "INFO: Detected master nodes: $master_count"
echo "INFO: Detected worker nodes: $worker_count"

### Generate the 'install-config.yaml' file using a heredoc.
echo "--- Generating 'install-config.yaml'..."
cat << EOF > "./$CLUSTER_NAME/orig/install-config.yaml"
apiVersion: v1
baseDomain: $BASE_DOMAIN
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: $worker_count
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: $master_count
metadata:
  name: $CLUSTER_NAME
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: $MACHINE_NETWORK
  serviceNetwork:
  - $SERVICE_NETWORK
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $HOST_PREFIX
platform:
  none: {}
fips: false
pullSecret: '$(cat "$PULL_SECRET")'
sshKey: |
  $SSH_KEY_01
EOF
echo "INFO: Base 'install-config.yaml' created."

### Append the second SSH key if it exists.
if [[ -n "${SSH_KEY_02:-}" ]]; then
    echo "INFO: Appending second SSH key..."
    cat << EOF >> "./$CLUSTER_NAME/orig/install-config.yaml"
  $SSH_KEY_02
EOF
fi

### Append mirror registry settings if the certificate file is present.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    echo "INFO: Appending mirror registry and trusted certificate information..."
    cat << EOF >> "./$CLUSTER_NAME/orig/install-config.yaml"
additionalTrustBundle: |
$(sed 's/^/  /' "$MIRROR_REGISTRY_CRT_FILE")
imageDigestSources:
- mirrors:
  - $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
fi
echo "INFO: 'install-config.yaml' generation complete."

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### Display the directory structure for verification.
echo "--- Verifying generated files in the output directory..."
if command -v tree >/dev/null 2>&1; then
    echo "INFO: Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME"
else
    echo "INFO: 'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "$CLUSTER_NAME"
fi
echo "--- 'install-config.yaml' is ready. Proceed to the next step."