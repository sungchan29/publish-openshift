#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Image Tag Mirrors
### ---------------------------------------------------------------------------------
### This script creates an ImageTagMirrorSet (ITMS) manifest to redirect requests for
### specific support and logging tool images to a local mirror registry.

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
### Generate ImageTagMirrorSet Manifest
### ---------------------------------------------------------------------------------
### Only proceed if a mirror registry certificate is configured, which indicates a disconnected environment.
if [[ -f "${MIRROR_REGISTRY_CRT_FILE:-}" ]] && [[ -s "${MIRROR_REGISTRY_CRT_FILE:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "-- Creating ImageTagMirrorSet for support-tools & eventrouter..."
    cat << EOF > "$ADDITIONAL_MANIFEST/itms-openshift-tools.yaml"
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
    name: openshift-tools
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/openshift-logging/eventrouter-rhel9
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
  - mirrors:
    - ${MIRROR_REGISTRY}/rhel9/support-tools
    source: registry.redhat.io/rhel9/support-tools
EOF
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping ImageTagMirrorSet (ITMS) configuration. Reason: Mirror registry certificate not found (assuming connected install)."
fi