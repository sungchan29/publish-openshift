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

if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    cat << EOF > $ADDITIONAL_MANIFEST/itms-support-tools-eventrouter.yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
    name: support-tools-eventrouter
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/rhel9/support-tools
    source: registry.redhat.io/rhel9/support-tools
  - mirrors:
    - ${MIRROR_REGISTRY}/openshift-logging/eventrouter-rhel9
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
EOF
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch ImageTagMirrorSet(support-tools-eventrouter)."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi