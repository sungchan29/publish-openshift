#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Image Tag Mirrors
### ---------------------------------------------------------------------------------
### This script creates an ImageTagMirrorSet (ITMS) to redirect requests for
### specific support and logging tool images to a local mirror registry.

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
### Generate ImageTagMirrorSet Manifest
### ---------------------------------------------------------------------------------
### Check for the mirror registry certificate file as a prerequisite.
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    echo "INFO: Mirror registry certificate file found. Generating ITMS manifest..."
    
    cat << EOF > "$ADDITIONAL_MANIFEST/itms-support-tools-eventrouter.yaml"
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
    name: support-tools-eventrouter
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/openshift-logging/eventrouter-rhel9
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
  - mirrors:
    - ${MIRROR_REGISTRY}/rhel9/support-tools
    source: registry.redhat.io/rhel9/support-tools
EOF

    echo "INFO: ITMS manifest 'itms-support-tools-eventrouter.yaml' created successfully."
    echo "--- Image tag mirroring is configured for support tools and event router."
else
    echo "INFO: Skipping ITMS configuration. Mirror registry certificate file was not found."
    echo "--- Script execution finished without making changes."
fi