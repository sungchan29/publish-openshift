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

###
###
###
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    cat << EOF > $ADDITIONAL_MANIFEST/operatorhub-disabled.yaml
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi

###
### oc get operatorhubs.config.openshift.io cluster
###