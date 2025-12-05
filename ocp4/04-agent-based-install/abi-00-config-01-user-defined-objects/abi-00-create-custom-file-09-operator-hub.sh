#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure OperatorHub for Disconnected Environment
### ---------------------------------------------------------------------------------
### This script creates a manifest to disable all default OperatorHub sources.
### This is essential for disconnected or air-gapped installations to prevent
### the cluster from attempting to connect to external, public registries.

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
### Generate OperatorHub Manifest
### ---------------------------------------------------------------------------------
### Only proceed if a mirror registry certificate is configured, which indicates a disconnected environment.
if [[ -f "${MIRROR_REGISTRY_CRT_FILE:-}" ]] && [[ -s "${MIRROR_REGISTRY_CRT_FILE:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Generate OperatorHub Manifest..."
    printf "%-12s%-80s\n" "[INFO]" "-- Generating OperatorHub manifest to disable default sources..."
    cat << EOF > "$ADDITIONAL_MANIFEST/operatorhub-disabled.yaml"
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping OperatorHub configuration. Reason: Mirror registry certificate not found (assuming connected install)."
fi