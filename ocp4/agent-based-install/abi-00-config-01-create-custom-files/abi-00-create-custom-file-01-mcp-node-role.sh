#!/bin/bash

### Enable strict mode
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

if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
    ### Create MachineConfigPool
    for node_role_selector in "${NODE_ROLE_SELECTORS[@]}"; do
        node_role=$(          echo ${node_role_selector} |awk -F "--" '{print  $1}' )
        node_name_selector=$( echo ${node_role_selector} |awk -F "--" '{print  $1}' )

        cat << EOF > $ADDITIONAL_MANIFEST/mcp-${node_role}.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: $node_role
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values:
        - worker
        - ${node_role}
  nodeSelector:
    matchExpressions:
     - key: node-role.kubernetes.io/${node_role}
       operator: Exists
EOF
        if [[ "$node_role" != "infra" ]]; then
            cat << EOF >> $ADDITIONAL_MANIFEST/mcp-${node_role}.yaml
     - key: node-role.kubernetes.io/infra
       operator: DoesNotExist
EOF
        fi
    done
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch MachineConfigPool."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi