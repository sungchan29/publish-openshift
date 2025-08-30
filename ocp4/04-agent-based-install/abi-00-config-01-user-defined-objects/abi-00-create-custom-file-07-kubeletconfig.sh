#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

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
for role in "master" "worker"; do
    cat << EOF > $ADDITIONAL_MANIFEST/${role}-kubeletconfig.yaml
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


###
### oc get kubeletconfigs.machineconfiguration.openshift.io
###