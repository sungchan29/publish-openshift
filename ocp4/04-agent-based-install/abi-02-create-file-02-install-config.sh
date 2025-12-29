#!/bin/bash

### ---------------------------------------------------------------------------------
### Create Installation Manifests
### ---------------------------------------------------------------------------------
### This script generates the core 'install-config.yaml' file, which defines the
### cluster's high-level configuration based on your setup.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
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
validate_file "$PULL_SECRET"

if [[ -z "$(cat "$PULL_SECRET")" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The pull secret file at '$PULL_SECRET' is empty. Exiting..."
    exit 1
fi

### Validate pull secret JSON format if 'jq' is available.
if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$PULL_SECRET" >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[ERROR]" "    The pull secret file at '$PULL_SECRET' is not valid JSON. Please correct its format. Exiting..."
        exit 1
    fi
fi

### Check for the existence of the 'agent-config.yaml' file, which is required.
if [[ ! -f "./$CLUSTER_NAME/orig/agent-config.yaml" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required file './$CLUSTER_NAME/orig/agent-config.yaml' not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Count Nodes and Create 'install-config.yaml'
### ---------------------------------------------------------------------------------
### Count the number of master and worker nodes from the 'agent-config.yaml' file.
printf "%-8s%-80s\n" "[INFO]" "=== Generating 'install-config.yaml' ==="
printf "%-8s%-80s\n" "[INFO]" "--- Counting nodes from 'agent-config.yaml' ..."
master_count=$(grep -E "^\s*role:\s*master\s*$" "./$CLUSTER_NAME/orig/agent-config.yaml" | wc -l || true)
worker_count=$(grep -E "^\s*role:\s*worker\s*$" "./$CLUSTER_NAME/orig/agent-config.yaml" | wc -l || true)
printf "%-8s%-80s\n" "[INFO]" "    -- Detected master nodes: $master_count"
printf "%-8s%-80s\n" "[INFO]" "    -- Detected worker nodes: $worker_count"

### Generate the 'install-config.yaml' file using a heredoc.
printf "%-8s%-80s\n" "[INFO]" "--- Initialize the YAML file with base cluster configuration."
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
  - cidr: $MACHINE_NETWORK_CIDR
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

### Append the second SSH key to the configuration if it is defined.
if [[ -n "${SSH_KEY_02:-}" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "--- Appending second SSH key..."
    cat << EOF >> "./$CLUSTER_NAME/orig/install-config.yaml"
  $SSH_KEY_02
EOF
fi

### Append mirror registry and trusted certificate information if the CA file is present.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "--- Appending mirror registry and trusted certificate information..."
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

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### Display the directory structure for user verification.
printf "%-8s%-80s\n" "[INFO]" "=== Verifying generated files ==="
printf "%-8s%-80s\n" "[INFO]" "    Displaying directory structure for '$CLUSTER_NAME':"
if command -v tree >/dev/null 2>&1; then
    tree "$CLUSTER_NAME"
else
    printf "%-8s%-80s\n" "[INFO]" "    'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "$CLUSTER_NAME"
fi
echo ""