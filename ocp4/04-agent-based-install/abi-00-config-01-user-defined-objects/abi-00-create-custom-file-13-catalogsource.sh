#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions."
    exit 1
fi

###
###
###
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)
    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
            if [[ "certified" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
                    echo "[INFO] IDMS_OLM_CERTIFIED is set. Creating CatalogSource for 'certified' operator."
                else
                    echo "[INFO] IDMS_OLM_CERTIFIED is not set. Skipping CatalogSource creation for 'certified' operator."
                    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
                    continue
                fi
            elif [[ "community" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
                    echo "[INFO] IDMS_OLM_COMMUNITY is set. Creating CatalogSource for 'community' operator."
                else
                    echo "[INFO] IDMS_OLM_COMMUNITY is not set. Skipping CatalogSource creation for 'community' operator."
                    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
                    continue
                fi
            fi
            cat << EOF > "$ADDITIONAL_MANIFEST/cs-${catalog}-operator-index.yaml"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-${catalog}-operator-index
  namespace: openshift-marketplace
spec:
  image: ${MIRROR_REGISTRY}/olm-${catalog}/redhat/${catalog}-operator-index:v${ocp_major_minor}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 20m
EOF
        done
    else
        echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
    fi
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi

###
### oc -n openshift-marketplace get catalogsources.operators.coreos.com
###