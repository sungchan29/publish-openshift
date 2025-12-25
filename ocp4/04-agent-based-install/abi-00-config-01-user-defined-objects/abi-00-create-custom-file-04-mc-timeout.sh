#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Shell Session Timeout
### ---------------------------------------------------------------------------------
### This script generates a MachineConfig manifest to enforce a shell session timeout
### on all cluster nodes, enhancing security by logging out idle sessions.

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
### Generate Timeout Configuration
### ---------------------------------------------------------------------------------
printf "%-12s%-80s\n" "[INFO]" "Generating MachineConfig to Set Session Timeout ..."
### Create a temporary file containing the timeout setting.
printf "%-12s%-80s\n" "[INFO]" "-- Generating temporary timeout configuration file..."
cat <<EOF > "$CUSTOM_CONFIG_DIR/timeout.txt"
export TMOUT=300
EOF
### Check if the timeout configuration file exists and is not empty before proceeding.
if [[ -f "$CUSTOM_CONFIG_DIR/timeout.txt" ]] && [[ -s "$CUSTOM_CONFIG_DIR/timeout.txt" ]]; then
    ### Loop through master and worker roles to create a separate MachineConfig for each.
    for role in "master" "worker"; do
        printf "%-12s%-80s\n" "[INFO]" "-- Creating Butane config for '$role' nodes..."
        cat <<EOF > "$BUTANE_BU_DIR/99-${role}-timeout.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-timeout
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/profile.d/99-timeout.sh
    mode: 0644
    overwrite: true
    contents:
      source: data:text/plain;charset=utf-8;base64,$(base64 -w0 "$CUSTOM_CONFIG_DIR/timeout.txt")
EOF
        ### Transpile the Butane file into a MachineConfig YAML file.
        if [[ -f "$BUTANE_BU_DIR/99-${role}-timeout.bu" ]]; then
            printf "%-12s%-80s\n" "[INFO]" "-- Transpiling Butane file to MachineConfig for '$role' nodes..."
            ./butane "$BUTANE_BU_DIR/99-${role}-timeout.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-timeout.yaml"
        else
            printf "%-12s%-80s\n" "[ERROR]" "Failed to create Butane configuration file for role '$role'. Exiting..."
            exit 1
        fi
    done
else
    printf "%-12s%-80s\n" "[ERROR]" "Skipping shell timeout configuration. Reason: Temporary config file is missing or empty."
fi