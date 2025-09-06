#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure OperatorHub for Disconnected Environment
### ---------------------------------------------------------------------------------
### This script creates a manifest to disable all default OperatorHub sources.
### This is essential for disconnected or air-gapped installations to prevent
### the cluster from attempting to connect to external registries.

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
### Generate OperatorHub Manifest
### ---------------------------------------------------------------------------------
### Check for the mirror registry certificate file as a condition for proceeding.
if [[ -f ${MIRROR_REGISTRY_CRT_FILE} ]] && [[ -s ${MIRROR_REGISTRY_CRT_FILE} ]]; then
    echo "INFO: Mirror registry certificate file found. Generating OperatorHub manifest to disable default sources..."
    
    cat << EOF > "$ADDITIONAL_MANIFEST/operatorhub-disabled.yaml"
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF

    echo "INFO: Manifest 'operatorhub-disabled.yaml' created successfully."
    echo "--- The cluster will not use default OperatorHub sources after installation."
else
    echo "INFO: Skipping OperatorHub configuration. Mirror registry certificate file was not found."
    echo "--- Script execution finished without making changes."
fi