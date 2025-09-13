#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Operator Image Mirrors
### ---------------------------------------------------------------------------------
### This script creates ImageDigestMirrorSet (IDMS) manifests to redirect OLM image
### sources to a local mirror registry, enabling operator installation in
### a disconnected environment.

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
### Generate ImageDigestMirrorSet Manifests
### ---------------------------------------------------------------------------------
### Only proceed if a mirror registry certificate is configured, which indicates a disconnected environment.
if [[ -f "${MIRROR_REGISTRY_CRT_FILE:-}" ]] && [[ -s "${MIRROR_REGISTRY_CRT_FILE:-}" ]]; then
    ocp_major_minor=$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)
    if [[ -n "$OLM_OPERATORS" ]]; then
        for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g' | grep -E '^(redhat|certified|community)$' ); do
            printf "%-12s%-80s\n" "[INFO]" "Processing IDMS for '$catalog' operators..."            
            if [[ "redhat" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_REDHAT" ]] && [[ -s "$IDMS_OLM_REDHAT" ]]; then
                    printf "%-12s%-80s\n" "[INFO]" "-- Copying provided IDMS file for Red Hat operators."
                    cp -f "$IDMS_OLM_REDHAT" "$ADDITIONAL_MANIFEST/idms-olm-redhat.yaml"
                else
                    printf "%-12s%-80s\n" "[INFO]" "-- Generating a default manifest."
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
                fi
            elif [[ "certified" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_CERTIFIED" ]] && [[ -s "$IDMS_OLM_CERTIFIED" ]]; then
                    printf "%-12s%-80s\n" "[INFO]" "-- Copying provided IDMS file for Certified operators."
                    cp -f "$IDMS_OLM_CERTIFIED" "$ADDITIONAL_MANIFEST/idms-olm-certified.yaml"
                else
                    printf "%-12s%-80s\n" "[WARN]" "IDMS file for 'certified' operators not configured (IDMS_OLM_CERTIFIED is empty or file not found)."
                fi
            elif [[ "community" == "$catalog" ]]; then
                if [[ -f "$IDMS_OLM_COMMUNITY" ]] && [[ -s "$IDMS_OLM_COMMUNITY" ]]; then
                    printf "%-12s%-80s\n" "[INFO]" "-- Copying provided IDMS file for Community operators."
                    cp -f "$IDMS_OLM_COMMUNITY" "$ADDITIONAL_MANIFEST/idms-olm-community.yaml"
                else
                    printf "%-12s%-80s\n" "[WARN]" "IDMS file for 'community' operators not configured (IDMS_OLM_COMMUNITY is empty or file not found)."
                fi
            fi
        done
    else
        printf "%-12s%-80s\n" "[WARN]" "OLM_OPERATORS variable is not set."
    fi
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping IDMS manifest generation. Reason: Mirror registry certificate not found (assuming connected install)."
fi