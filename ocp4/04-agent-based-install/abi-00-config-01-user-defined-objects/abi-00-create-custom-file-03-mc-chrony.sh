#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Network Time Protocol (NTP)
### ---------------------------------------------------------------------------------
### This script automates the configuration of NTP for all OpenShift cluster nodes.
### It uses the 'butane' tool to create a MachineConfig that sets the specified
### NTP servers in the '/etc/chrony.conf' file on each node.

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
### Generate Chrony Configuration
### ---------------------------------------------------------------------------------
### Check if an NTP server is configured. If not, exit gracefully.
if [[ -n "$NTP_SERVER_01" ]]; then
    echo "INFO: NTP server configured. Generating chrony MachineConfig..."
    butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

    ### Loop through master and worker roles to create a MachineConfig for each.
    for role in "master" "worker"; do
        echo "INFO: -> Creating Butane config for '$role' nodes."
        cat << EOF > "$BUTANE_BU_DIR/99-${role}-chrony.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-chrony
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/chrony.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        pool $NTP_SERVER_01 iburst
EOF
        
        ### Append the second NTP server if it is configured.
        if [[ -n $NTP_SERVER_02 ]]; then
            cat << EOF >> "$BUTANE_BU_DIR/99-${role}-chrony.bu"
        pool $NTP_SERVER_02 iburst
EOF
        fi
        
        ### Append standard chrony configuration options.
        cat << EOF >> "$BUTANE_BU_DIR/99-${role}-chrony.bu"
        driftfile /var/lib/chrony/drift
        makestep 1.0 3
        rtcsync
        logdir /var/log/chrony
EOF
        
        ### Transpile the Butane file into a MachineConfig YAML file.
        echo "INFO: -> Transpiling Butane file to MachineConfig for '$role' nodes."
        ./butane "$BUTANE_BU_DIR/99-${role}-chrony.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-chrony.yaml"
        echo "INFO: -> Successfully created MachineConfig for '$role' nodes."
    done
    echo "--- NTP configuration is complete. The MachineConfigs are ready for the installer."
else
    echo "INFO: No NTP server specified. Skipping this step."
    echo "--- Script execution finished without making changes."
fi