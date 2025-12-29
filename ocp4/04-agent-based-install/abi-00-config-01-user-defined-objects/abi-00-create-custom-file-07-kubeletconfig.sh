#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Node-level Kubelet Settings
### ---------------------------------------------------------------------------------
### This script creates KubeletConfig manifests for both master and worker nodes
### to apply custom configurations such as automatic resource reservation and
### log levels.
###
### References:
### - KubeletConfig API: https://docs.redhat.com/it/documentation/openshift_container_platform/4.19/html/machine_apis/kubeletconfig-machineconfiguration-openshift-io-v1
### - CRI-O Log Rotation: https://access.redhat.com/solutions/4924281
### - Kubelet Log Level: https://docs.redhat.com/it/documentation/openshift_container_platform/4.19/html/api_overview/editing-kubelet-log-level-verbosity
### - Auto-Sizing Node Resources: https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/nodes/nodes-nodes-resources-configuring
###

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
### Generate KubeletConfig Manifests
### ---------------------------------------------------------------------------------
printf "%-12s%-80s\n" "[INFO]" "Generating KubeletConfig manifests for master and worker nodes..."
### Loop through master and worker roles to create a KubeletConfig for each.
for role in "master" "worker"; do
    printf "%-12s%-80s\n" "[INFO]" "-- Creating KubeletConfig manifest for the '$role' role..."
    cat << EOF > "$ADDITIONAL_MANIFEST/${role}-kubeletconfig.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: ${role}-set-kubelet-config
spec:
  autoSizingReserved: true
  logLevel: 3
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${role}: ""
EOF
done