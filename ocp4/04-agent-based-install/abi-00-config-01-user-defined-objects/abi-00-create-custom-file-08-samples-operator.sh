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
### Cluster Samples Operator
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/images/configuring-samples-operator#configuring-samples-operator
###
cat << EOF > $ADDITIONAL_MANIFEST/sample-operator.yaml
apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  architectures:
  - x86_64
  managementState: Removed
EOF

###
### oc get config.samples.operator.openshift.io cluster -o yaml
###