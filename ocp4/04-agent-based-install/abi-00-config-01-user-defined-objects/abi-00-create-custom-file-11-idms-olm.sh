#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Operator Image Mirrors
### ---------------------------------------------------------------------------------
### This script creates ImageDigestMirrorSet (IDMS) manifests to redirect OLM image
### sources to a local mirror registry, enabling operator installation in
### a disconnected environment.

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
### Generate ImageDigestMirrorSet Manifests
### ---------------------------------------------------------------------------------
### Check for the mirror registry certificate file as a prerequisite.
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    echo "INFO: Mirror registry certificate file found. Starting IDMS manifest generation..."
    ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)

    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
            echo "INFO: -> Processing IDMS for '$catalog' operators."
            
            if [[ "redhat" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_REDHAT" ]] && [[ -s "$IDMS_OLM_REDHAT" ]]; then
                    echo "INFO:   -> Copying provided IDMS file for Red Hat operators."
                    cp -f "$IDMS_OLM_REDHAT" "$ADDITIONAL_MANIFEST/idms-olm-redhat.yaml"
                    echo "INFO:   -> IDMS file copied successfully."
                else
                    echo "INFO:   -> No IDMS file provided for Red Hat operators. Generating a default one."
                    cat << EOF > "$ADDITIONAL_MANIFEST/idms-olm-redhat.yaml"
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: olm-redhat
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/olm-redhat
    source: registry.redhat.io
EOF
                    echo "INFO:   -> Default IDMS manifest created for Red Hat operators."
                fi
            elif [[ "certified" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
                    echo "INFO:   -> Copying provided IDMS file for Certified operators."
                    cp -f "$IDMS_OLM_CERTIFIED" "$ADDITIONAL_MANIFEST/idms-olm-certified.yaml"
                    echo "INFO:   -> IDMS file copied successfully."
                else
                    echo "WARNING: -> IDMS file for Certified operators was not found. Skipping."
                fi
            elif [[ "community" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
                    echo "INFO:   -> Copying provided IDMS file for Community operators."
                    cp -f "$IDMS_OLM_COMMUNITY" "$ADDITIONAL_MANIFEST/idms-olm-community.yaml"
                    echo "INFO:   -> IDMS file copied successfully."
                else
                    echo "WARNING: -> IDMS file for Community operators was not found. Skipping."
                fi
            fi
        done
        echo "--- All selected IDMS manifests have been created."
    else
        echo "INFO: OLM_OPERATORS variable is not set. No IDMS manifests will be created."
    fi
else
    echo "WARNING: Mirror registry certificate file '${MIRROR_REGISTRY_CRT_FILE}' does not exist or is empty. Skipping creation of ImageDigestMirrorSet manifests."
    echo "--- Script execution finished without making changes."
fi