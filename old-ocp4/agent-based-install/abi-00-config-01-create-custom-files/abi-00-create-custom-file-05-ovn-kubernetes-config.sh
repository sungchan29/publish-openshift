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

### How to change the 'v4InternalSubnet' of OVN-K using Assisted Installer?
### https://access.redhat.com/solutions/7056664
if [[ -n $INTERNAL_MASQUERADE_SUBNET || -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
    cat << EOF > $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
EOF
    if [[ -n $INTERNAL_MASQUERADE_SUBNET ]]; then
cat << EOF >> $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $INTERNAL_MASQUERADE_SUBNET
EOF
    fi
    if [[ -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
cat << EOF >> $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
      ipv4:
EOF
        if [[ -n $INTERNAL_JOIN_SUBNET ]]; then
cat << EOF >> $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
        internalJoinSubnet: $INTERNAL_JOIN_SUBNET
EOF
        fi
        if [[ -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
cat << EOF >> $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
        internalTransitSwitchSubnet: $INTERNAL_TRANSIT_SWITCH_SUBNET
EOF
        fi
    fi
cat << EOF >> $ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml
    type: OVNKubernetes
EOF
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch OVN Kubernetes(internalMasqueradeSubnet, internalJoinSubnet, internalTransitSwitchSubnet)."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi