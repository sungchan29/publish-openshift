#!/bin/bash

### ---------------------------------------------------------------------------------
### Customize OVN-Kubernetes Subnets
### ---------------------------------------------------------------------------------
### This script creates a custom 'Network' manifest to override the default
### OVN-Kubernetes internal IP subnets.
###
### OVN-Kubernetes, the default network provider in OpenShift Container Platform 4.14 and later versions, internally uses the following IP address subnet ranges
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/cidr-range-definitions#cidr-range-definitions
### How to change the 'v4InternalSubnet' of OVN-K using Assisted Installer?
###   https://access.redhat.com/solutions/7056664
###
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin#nw-ovn-k-day-2-masq-subnet_configure-ovn-kubernetes-subnets
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin#nw-ovn-kubernetes-change-transit-subnet_configure-ovn-kubernetes-subnets
###

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration
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
### Generate Network Manifest
### ---------------------------------------------------------------------------------
### Check if any of the optional OVN-Kubernetes subnets are defined.
if [[ -n $INTERNAL_MASQUERADE_SUBNET || -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
    echo "INFO: Custom OVN-Kubernetes subnets are configured. Generating network manifest..."

    ### Create the base YAML file for the Network object.
    cat << EOF > "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
EOF

    ### Conditionally add the masquerade subnet configuration.
    if [[ -n $INTERNAL_MASQUERADE_SUBNET ]]; then
        cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $INTERNAL_MASQUERADE_SUBNET
EOF
    fi

    ### Conditionally add the join and transit subnets.
    if [[ -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
        cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
      ipv4:
EOF
        if [[ -n $INTERNAL_JOIN_SUBNET ]]; then
            cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
        internalJoinSubnet: $INTERNAL_JOIN_SUBNET
EOF
        fi
        if [[ -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
            cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
        internalTransitSwitchSubnet: $INTERNAL_TRANSIT_SWITCH_SUBNET
EOF
        fi
    fi
    
    ### Append the required network type.
    cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
    type: OVNKubernetes
EOF
    
    echo "INFO: 'ovn-kubernetes-config.yaml' created successfully."
else
    echo "INFO: No custom OVN-Kubernetes subnets specified. Skipping this step."
    echo "--- Script execution finished without making changes."
fi