#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Node-level Kubelet Settings
### ---------------------------------------------------------------------------------
### This script creates a KubeletConfig manifest for both master and worker nodes
### to apply custom configurations such as automatic resource reservation and
### log levels.
###
### KubeletConfig [machineconfiguration.openshift.io/v1]
###   https://docs.redhat.com/it/documentation/openshift_container_platform/4.19/html/machine_apis/kubeletconfig-machineconfiguration-openshift-io-v1#spec-4
### Modification of log rotation of CRI-O in Openshift 4
###   https://access.redhat.com/solutions/4924281
### The containerLogMaxSize and containerLogMaxFiles values are as follows by default.
###   NODE_NAME=""
###   oc get --raw /api/v1/nodes/${NODE_NAME}/proxy/configz| jq '.kubeletconfig|.kind="KubeletConfiguration"|.apiVersion="kubelet.config.k8s.io/v1beta1"' | grep -i containerLog
### Editing kubelet log level verbosity
###   https://docs.redhat.com/it/documentation/openshift_container_platform/4.19/html/api_overview/editing-kubelet-log-level-verbosity
###
### Automatically allocating resources for nodes
###   https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/nodes/nodes-nodes-resources-configuring#nodes-nodes-resources-configuring-auto_nodes-nodes-resources-configuring
###   https://access.redhat.com/solutions/6988837
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
### Generate KubeletConfig Manifests
### ---------------------------------------------------------------------------------
echo "INFO: Generating KubeletConfig manifests for master and worker nodes..."

for role in "master" "worker"; do
    echo "INFO: -> Creating KubeletConfig for the '$role' role."
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
    echo "INFO: -> KubeletConfig manifest for '$role' created successfully at '$ADDITIONAL_MANIFEST/${role}-kubeletconfig.yaml'."
done

echo "--- KubeletConfig generation is complete. These files will be applied during installation."