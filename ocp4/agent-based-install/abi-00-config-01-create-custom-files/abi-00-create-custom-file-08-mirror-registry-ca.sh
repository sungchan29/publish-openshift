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

### 1. registry ca trust configmap
### 2. add trusted ca
if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    if [[ "${MIRROR_REGISTRY}" == *:* ]]; then
        MIRROR_REGISTRY_STR="  ${MIRROR_REGISTRY_HOSTNAME}..${MIRROR_REGISTRY_PORT}: |"
    else
        MIRROR_REGISTRY_STR="  ${MIRROR_REGISTRY_HOSTNAME}: |"
    fi
    cat << EOF >  $ADDITIONAL_MANIFEST/configmap_mirror-registry-ca.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  updateservice-registry: |
$(xargs -d '\n' -I {} echo "    {}" < "${MIRROR_REGISTRY_TRUST_FILE}")
$(echo "${MIRROR_REGISTRY_STR}")
$(xargs -d '\n' -I {} echo "    {}" < "${MIRROR_REGISTRY_TRUST_FILE}")
EOF

    cat << EOF > $ADDITIONAL_MANIFEST/image-additional-trusted-ca.yaml
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch Configmap(mirror-registry-ca, additionalTrustedCA)."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi