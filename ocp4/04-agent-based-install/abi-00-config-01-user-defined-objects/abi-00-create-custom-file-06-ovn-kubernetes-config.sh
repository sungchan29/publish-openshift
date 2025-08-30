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
### OVN-Kubernetes, the default network provider in OpenShift Container Platform 4.14 and later versions, internally uses the following IP address subnet ranges
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/cidr-range-definitions#cidr-range-definitions
### How to change the 'v4InternalSubnet' of OVN-K using Assisted Installer?
###   https://access.redhat.com/solutions/7056664
###
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin#nw-ovn-k-day-2-masq-subnet_configure-ovn-kubernetes-subnets
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin#nw-ovn-kubernetes-change-transit-subnet_configure-ovn-kubernetes-subnets
###

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
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi