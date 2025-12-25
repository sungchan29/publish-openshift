#!/bin/bash

### ---------------------------------------------------------------------------------
### Set Cluster Timezone
### ---------------------------------------------------------------------------------
### This script generates a MachineConfig manifest to configure a custom timezone
### ('Asia/Seoul') for all nodes in the OpenShift cluster.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### Set the Butane specification version based on the OCP version (e.g., 4.19.9 -> 4.19.0).
butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

### ---------------------------------------------------------------------------------
### Generate Timezone MachineConfig
### ---------------------------------------------------------------------------------
### Create a Butane configuration for both master and worker roles to set the timezone
### to 'Asia/Seoul' using a systemd service.
### Reference: https://access.redhat.com/solutions/5487331
###
printf "%-12s%-80s\n" "[INFO]" "Generating MachineConfig to set timezone to 'Asia/Seoul'"
for role in "master" "worker"; do
    printf "%-12s%-80s\n" "[INFO]" "-- Creating Butane config for '$role' nodes..."
    cat << EOF > "$BUTANE_BU_DIR/99-${role}-timezone.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-timezone
  labels:
    machineconfiguration.openshift.io/role: ${role}
systemd:
  units:
  - contents: |
      [Unit]
      Description=Set timezone to Asia/Seoul
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/timedatectl set-timezone Asia/Seoul

      [Install]
      WantedBy=multi-user.target
    enabled: true
    name: set-timezone.service
EOF
    printf "%-12s%-80s\n" "[INFO]" "-- Transpiling Butane file to MachineConfig for '$role' nodes..."
    ./butane "$BUTANE_BU_DIR/99-${role}-timezone.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-timezone.yaml"
done