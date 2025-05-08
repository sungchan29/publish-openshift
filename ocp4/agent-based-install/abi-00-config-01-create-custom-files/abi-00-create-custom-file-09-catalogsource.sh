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

### Convert OCP_VERSION to major-minor format for operator catalog
ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)
if [[ -z "$ocp_major_minor" || ! "$ocp_major_minor" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "[ERROR] OCP_VERSION must be in a format that allows extracting major-minor version (e.g., 4.17.25) for operator catalog. Current value: '$OCP_VERSION'"
    exit 1
fi

### Generate CatalogSource YAML files
if [[ -f "${MIRROR_REGISTRY_TRUST_FILE}" ]]; then
    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
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
    fi
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed: $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to generate CatalogSource YAML files."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi