#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions."
    exit 1
fi

validate_cidr    "MACHINE_NETWORK"      "$MACHINE_NETWORK"      "install-config.yaml"
validate_cidr    "SERVICE_NETWORK"      "$SERVICE_NETWORK"      "install-config.yaml"
validate_cidr    "CLUSTER_NETWORK_CIDR" "$CLUSTER_NETWORK_CIDR" "install-config.yaml"
validate_prefix  "HOST_PREFIX"          "$HOST_PREFIX"          "install-config.yaml"
validate_ssh_key "SSH_KEY_01"           "$SSH_KEY_01"           "install-config.yaml"

if [[ -n "$SSH_KEY_02" ]]; then
    validate_ssh_key "SSH_KEY_02" "$SSH_KEY_02" "install-config.yaml"
fi

validate_file "$PULL_SECRET"

if [[ -z "$(cat "$PULL_SECRET")" ]]; then
    echo "[ERROR] PULL_SECRET does not exist or is empty."
    exit 1
fi

### Validate pullSecret JSON format
if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$PULL_SECRET" >/dev/null 2>&1; then
        echo "[ERROR] PULL_SECRET is not a valid JSON file."
        exit 1
    fi
fi
### Check agent-config.yaml
if [[ ! -f "./$CLUSTER_NAME/orig/agent-config.yaml" ]]; then
    echo "[ERROR] The file './$CLUSTER_NAME/orig/agent-config.yaml' does not exist."
    echo "[INFO] To resolve this issue, execute the following command:"
    echo "[INFO] bash abi-02-create-file-01-agent-config.sh"
    exit 1
fi

### Count master and worker nodes
master_count=$(grep -E "^\s*role:\s*master\s*$" ./$CLUSTER_NAME/orig/agent-config.yaml | wc -l)
worker_count=$(grep -E "^\s*role:\s*worker\s*$" ./$CLUSTER_NAME/orig/agent-config.yaml | wc -l)

###
### Create install-config.yaml
###
cat << EOF > ./$CLUSTER_NAME/orig/install-config.yaml
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

### Append additional SSH key
if [[ -n "$SSH_KEY_02" ]]; then
    cat << EOF >> ./$CLUSTER_NAME/orig/install-config.yaml
  $SSH_KEY_02
EOF
fi

### Append mirror registry settings
if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
    cat << EOF >> ./$CLUSTER_NAME/orig/install-config.yaml
additionalTrustBundle: |
$(sed 's/^/  /' "$MIRROR_REGISTRY_TRUST_FILE")
imageDigestSources:
- mirrors:
  - $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images
  source: quay.io/openshift-release-dev/ocp-release
- mirrors:
  - $MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release
  source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
fi

### List directory structure (optional, for debugging)
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "$CLUSTER_NAME"
fi