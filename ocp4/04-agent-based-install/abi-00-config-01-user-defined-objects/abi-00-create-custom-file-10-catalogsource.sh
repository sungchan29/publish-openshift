#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Operator Catalog Sources
### ---------------------------------------------------------------------------------
### This script creates CatalogSource manifests for selected Operator catalogs,
### enabling the installation of operators from a disconnected mirror registry.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration file to load all necessary variables.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### Generate CatalogSource Manifests
### ---------------------------------------------------------------------------------
### Check for the mirror registry certificate file as a prerequisite.
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    echo "INFO: Mirror registry certificate file found. Starting CatalogSource configuration..."
    
    ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)

    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
            
            ### Validate IDMS file for specific catalogs (certified, community).
            if [[ "certified" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
                    echo "INFO: IDMS for 'certified' operators is set. Creating CatalogSource."
                else
                    echo "WARNING: IDMS_OLM_CERTIFIED is not set. Skipping CatalogSource for 'certified' operators."
                    continue
                fi
            elif [[ "community" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
                    echo "INFO: IDMS for 'community' operators is set. Creating CatalogSource."
                else
                    echo "WARNING: IDMS_OLM_COMMUNITY is not set. Skipping CatalogSource for 'community' operators."
                    continue
                fi
            fi

            ### Generate the CatalogSource manifest for the current catalog.
            echo "INFO: -> Generating CatalogSource for '$catalog' operators."
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
            echo "INFO: -> CatalogSource manifest 'cs-${catalog}-operator-index.yaml' created successfully."
        done
        echo "--- All selected CatalogSources have been created."
    else
        echo "INFO: OLM_OPERATORS variable is not set. No CatalogSources will be created."
    fi
else
    echo "INFO: Skipping CatalogSource configuration. Mirror registry certificate file was not found."
fi

echo "--- Script execution finished."