#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Samples Operator
### ---------------------------------------------------------------------------------
### This script creates a manifest to configure the Samples Operator to prevent it
### from installing sample image streams and templates, which saves resources.
###
### Cluster Samples Operator
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/images/configuring-samples-operator#configuring-samples-operator
###

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
### Generate Samples Operator Manifest
### ---------------------------------------------------------------------------------
echo "INFO: Generating Samples Operator manifest to set managementState to 'Removed'..."

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
echo "INFO: Manifest 'sample-operator.yaml' created successfully."
echo "--- The Samples Operator will not install default content during cluster installation."