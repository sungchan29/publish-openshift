#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Operator Catalog Sources
### ---------------------------------------------------------------------------------
### This script creates CatalogSource manifests for selected Operator catalogs,
### enabling the installation of operators from a disconnected mirror registry.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Generate CatalogSource Manifests
### ---------------------------------------------------------------------------------
### Only proceed if a mirror registry certificate is configured, which indicates a disconnected environment.
if [[ -f "${MIRROR_REGISTRY_CRT_FILE:-}" ]] && [[ -s "${MIRROR_REGISTRY_CRT_FILE:-}" ]]; then
    ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)
    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
            printf "%-12s%-80s\n" "[INFO]" "-- Configuring the '$catalog' CatalogSource..."
            ### For 'certified' and 'community' catalogs, validate that the required IDMS file path is configured.
            if [[ "certified" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
                    echo -n ""
                else
                    printf "%-12s%-80s\n" "[WARN]" "   Skipping CatalogSource for 'certified' operators.(IDMS_OLM_CERTIFIED is not set or file not found.)"
                    continue
                fi
            elif [[ "community" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
                    echo -n ""
                else
                    printf "%-12s%-80s\n" "[WARN]" "   Skipping CatalogSource for 'community' operators.(IDMS_OLM_COMMUNITY is not set or file not found.)"
                    continue
                fi
            fi
            ### Generate the CatalogSource manifest for the current catalog.
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
        printf "%-12s%-80s\n" "[WARN]" "OLM_OPERATORS variable is not set."
    fi
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping CatalogSource configuration. Reason: Mirror registry certificate not found (assuming connected install)."
fi