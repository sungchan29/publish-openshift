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
    if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
        cp -f "$IDMS_OLM_CERTIFIED" $ADDITIONAL_MANIFEST/idms-olm-certified.yaml
    fi
    if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
        cp -f "$IDMS_OLM_COMMUNITY" $ADDITIONAL_MANIFEST/idms-olm-community.yaml
    fi
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi

###
### oc get imagedigestmirrorsets.config.openshift.io
###