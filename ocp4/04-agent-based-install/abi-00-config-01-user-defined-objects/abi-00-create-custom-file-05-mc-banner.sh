#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Node Login Banner
### ---------------------------------------------------------------------------------
### This script creates a MachineConfig to set a custom login banner on all cluster
### nodes by modifying the /etc/motd file.
###
### https://access.redhat.com/solutions/6806681
###

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
### Generate Banner Configuration
### ---------------------------------------------------------------------------------
### Create a temporary file with the banner content.
echo "INFO: Generating temporary banner configuration file..."
cat <<EOF > "$CUSTOM_CONFIG_DIR/banner.txt"
*************************************************************************
*   This is a private computer facility.                                *
*************************************************************************
EOF

### Check if the banner file exists and is not empty.
if [[ -f "$CUSTOM_CONFIG_DIR/banner.txt" ]] && [[ -s "$CUSTOM_CONFIG_DIR/banner.txt" ]]; then
    echo "INFO: Banner file found. Generating MachineConfig for login banner..."
    
    ### Loop through master and worker roles to create a MachineConfig for each.
    for role in "master" "worker"; do
        echo "INFO: -> Creating Butane config for '$role' nodes."
        cat <<EOF > "$BUTANE_BU_DIR/99-${role}-vulnerability-mitigation-banner.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-banner
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/motd
    mode: 0644
    overwrite: true
    contents:
      source: data:text/plain;charset=utf-8;base64,$(base64 -w0 "$CUSTOM_CONFIG_DIR/banner.txt")
EOF
        
        ### Transpile the Butane file into a MachineConfig YAML file.
        if [[ -f "$BUTANE_BU_DIR/99-${role}-vulnerability-mitigation-banner.bu" ]]; then
            echo "INFO: -> Transpiling Butane file to MachineConfig for '$role' nodes."
            ./butane "$BUTANE_BU_DIR/99-${role}-vulnerability-mitigation-banner.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-vulnerability-mitigation-banner.yaml"
            echo "INFO: -> Successfully created MachineConfig for '$role' nodes."
        else
            echo "ERROR: Failed to create Butane configuration for role '$role'." >&2
            exit 1
        fi
    done
    echo "--- Login banner configuration is complete. The MachineConfigs are ready for the installer."
else
    echo "INFO: Skipping login banner configuration. The banner file was not created or is empty."
    echo "--- Script execution finished without making changes."
fi