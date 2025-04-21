#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Automatically allocating resources for nodes
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.16/html/nodes/nodes-nodes-resources-configuring#nodes-nodes-resources-configuring-auto_nodes-nodes-resources-configuring
### https://access.redhat.com/solutions/6988837
for role in "master" "worker"; do
    cat << EOF > $ADDITIONAL_MANIFEST/${role}-dynamic-node.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: ${role}-dynamic-node
spec:
  autoSizingReserved: true
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${role}: ""
EOF
done

if [[ $? -eq 0 ]]; then
    echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
else
    echo "[ERROR] Failed to patch KubeletConfig(dynamic-node)."
fi