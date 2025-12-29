#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Network Time Protocol (NTP)
### ---------------------------------------------------------------------------------
### This script generates a MachineConfig manifest to configure the Network Time
### Protocol (NTP) for all nodes in the OpenShift cluster, ensuring proper
### time synchronization.

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
### Generate Chrony (NTP) Configuration
### ---------------------------------------------------------------------------------
### Check if an NTP server is configured in the setup script. If not, skip gracefully.
if [[ -n "${NTP_SERVER_01:-}" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Generating MachineConfig to sync time with NTP server ..."
    butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"
    ### Loop through master and worker roles to create a separate MachineConfig for each.
    for role in "master" "worker"; do
        printf "%-12s%-80s\n" "[INFO]" "-- Creating Butane config for '$role' nodes..."
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
        ### Append the second NTP server to the configuration if it is defined.
        if [[ -n ${NTP_SERVER_02:-} ]]; then
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
        ### Transpile the Butane file into a MachineConfig YAML file using the butane binary.
        printf "%-12s%-80s\n" "[INFO]" "-- Transpiling Butane file to MachineConfig for '$role' nodes..."
        ./butane "$BUTANE_BU_DIR/99-${role}-chrony.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-chrony.yaml"
    done
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping NTP configuration. Reason: NTP_SERVER_01 is not set."
fi