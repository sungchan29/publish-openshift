#!/bin/bash

### ---------------------------------------------------------------------------------
### Customize OVN-Kubernetes Subnets
### ---------------------------------------------------------------------------------
### This script generates a custom 'Network' manifest to override the default
### internal IP subnets used by the OVN-Kubernetes network plugin.
###
### References:
### - OVN-Kubernetes CIDR Definitions: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/cidr-range-definitions#cidr-range-definitions
### - How to change v4InternalSubnet: https://access.redhat.com/solutions/7056664
### - Configure OVN-K subnets: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin
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
### Generate Network Manifest
### ---------------------------------------------------------------------------------
### Check if any of the optional OVN-Kubernetes subnet variables are defined in the configuration.
if [[ -n "${INTERNAL_MASQUERADE_SUBNET:-}" || -n "${INTERNAL_JOIN_SUBNET:-}" || -n "${INTERNAL_TRANSIT_SWITCH_SUBNET:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Custom OVN-Kubernetes subnets are configured..."
    printf "%-12s%-80s\n" "[INFO]" "-- Generating network manifest..."
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
    ### Conditionally add the internalMasqueradeSubnet configuration if the variable is set.
    if [[ -n "${INTERNAL_MASQUERADE_SUBNET:-}" ]]; then
        cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $INTERNAL_MASQUERADE_SUBNET
EOF
    fi
    ### Conditionally add the internalJoinSubnet and internalTransitSwitchSubnet if either is set.
    if [[ -n "${INTERNAL_JOIN_SUBNET:-}" || -n "${INTERNAL_TRANSIT_SWITCH_SUBNET:-}" ]]; then
        cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
      ipv4:
EOF
        if [[ -n "${INTERNAL_JOIN_SUBNET:-}" ]]; then
            cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
        internalJoinSubnet: $INTERNAL_JOIN_SUBNET
EOF
        fi
        if [[ -n "${INTERNAL_TRANSIT_SWITCH_SUBNET:-}" ]]; then
            cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
        internalTransitSwitchSubnet: $INTERNAL_TRANSIT_SWITCH_SUBNET
EOF
        fi
    fi
    ### Append the required network type to complete the manifest.
    cat << EOF >> "$ADDITIONAL_MANIFEST/ovn-kubernetes-config.yaml"
    type: OVNKubernetes
EOF
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping OVN-Kubernetes manifest generation. Reason: No custom subnets were specified."
fi