#!/bin/bash

### ---------------------------------------------------------------------------------
### Set Cluster Timezone
### ---------------------------------------------------------------------------------
### This script automates the configuration of a custom timezone for all OpenShift
### cluster nodes by creating and injecting a MachineConfig manifest.

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

butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

### ---------------------------------------------------------------------------------
### Generate Timezone MachineConfig
### ---------------------------------------------------------------------------------
### Create a Butane configuration for both master and worker roles to set the timezone.
###
### Custom Timezone
###   https://access.redhat.com/solutions/5487331
###
echo "INFO: Generating MachineConfig to set the timezone to 'Asia/Seoul'..."
for role in "master" "worker"; do
    echo "INFO: -> Creating Butane config for '$role' nodes."
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
      Description=set timezone
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=timedatectl set-timezone Asia/Seoul

      [Install]
      WantedBy=multi-user.target
    enabled: true
    name: set-timezone.service
EOF
    
    echo "INFO: -> Transpiling Butane file to MachineConfig for '$role' nodes."
    ./butane "$BUTANE_BU_DIR/99-${role}-timezone.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-timezone.yaml"
    echo "INFO: -> Successfully created MachineConfig for '$role' nodes."
done

echo "--- Timezone configuration is complete. The MachineConfig is ready for the installer."