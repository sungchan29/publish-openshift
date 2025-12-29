#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Samples Operator
### ---------------------------------------------------------------------------------
### This script creates a manifest to configure the Samples Operator, preventing it
### from installing default sample image streams and templates to conserve resources.
###
### Reference:
### - Cluster Samples Operator: https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/images/configuring-samples-operator

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
config_file="${ROOT_DIR}/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Config not found: $config_file"
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Generate Samples Operator Manifest
### ---------------------------------------------------------------------------------
printf "%-12s%-80s\n" "[INFO]" "Generating Samples Operator manifest..."
printf "%-12s%-80s\n" "[INFO]" "-- This will set the managementState to 'Removed' to prevent installation of default samples."
cat << EOF > "$ADDITIONAL_MANIFEST/sample-operator.yaml"
apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  architectures:
  - x86_64
  managementState: Removed
EOF