#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Additional Storage
### ---------------------------------------------------------------------------------
### This script generates MachineConfig manifests to configure an additional disk or
### partition for container storage ('/var/lib/containers'). The configuration is
### created using Butane and is applied during the cluster installation.

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
### Generate Storage Configuration
### ---------------------------------------------------------------------------------
### Check if an additional device is configured in the setup script. If not, exit gracefully.
if [[ -n "$ADD_DEVICE_NAME" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Generating storage MachineConfig manifests..."
    ### Validate that required variables for this process are set.
    validate_non_empty "PARTITION_LABEL" "$PARTITION_LABEL"
    validate_non_empty "FILESYSTEM_PATH" "$FILESYSTEM_PATH"
    validate_non_empty "BUTANE_BU_DIR" "$BUTANE_BU_DIR"
    validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

    ### Check if the required output directories exist.
    if [[ ! -d "$BUTANE_BU_DIR" || ! -d "$ADDITIONAL_MANIFEST" ]]; then
        printf "%-12s%-80s\n" "[ERROR]" "Required output directories for MachineConfig generation do not exist. Exiting..."
        exit 1
    fi

    ### Determine the type of device configuration (a full partition or an entire direct device).
    if [[ "$ADD_DEVICE_TYPE" == "PARTITION" ]]; then
        validate_non_empty "PARTITION_START_MIB" "$PARTITION_START_MIB"
        validate_non_empty "PARTITION_SIZE_MIB" "$PARTITION_SIZE_MIB"
        validate_non_empty "PARTITION_NUMBER" "$PARTITION_NUMBER"

        for role in "master" "worker"; do
            printf "%-12s%-80s\n" "[INFO]" "-- Creating Butane config for '$role' nodes..."
            cat << EOF > "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 98-${role}-${PARTITION_LABEL}
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  disks:
  - device: ${ADD_DEVICE_NAME}
    partitions:
    - label: ${PARTITION_LABEL}
      start_mib: ${PARTITION_START_MIB}
      size_mib: ${PARTITION_SIZE_MIB}
      number: ${PARTITION_NUMBER}
  filesystems:
    - device: /dev/disk/by-partlabel/${PARTITION_LABEL}
      path: ${FILESYSTEM_PATH}
      format: xfs
      mount_options: [defaults, prjquota]
      with_mount_unit: true
EOF
            printf "%-12s%-80s\n" "[INFO]" "-- Transpiling Butane file to MachineConfig for '$role' nodes..."
            ./butane "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu" -o "$ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml"
        done
    elif [[ "$ADD_DEVICE_TYPE" == "DIRECT" ]]; then
        printf "%-12s%-80s\n"     "[INFO]" "-- Configuring additional storage using a DIRECT device: '$ADD_DEVICE_NAME'..."
        for role in "master" "worker"; do
            printf "%-12s%-80s\n" "[INFO]" "-- Creating Butane config for '$role' nodes..."
            cat << EOF > "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 98-${role}-${PARTITION_LABEL}
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  filesystems:
    - device: ${ADD_DEVICE_NAME}
      path: ${FILESYSTEM_PATH}
      format: xfs
      mount_options: [defaults, prjquota]
      with_mount_unit: true
EOF
            printf "%-12s%-80s\n" "[INFO]" "-- Transpiling Butane file to MachineConfig for '$role' nodes..."
            ./butane "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu" -o "$ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml"
        done
    else
        printf "%-12s%-80s\n" "[ERROR]" "Invalid ADD_DEVICE_TYPE '$ADD_DEVICE_TYPE'. Must be 'PARTITION' or 'DIRECT'. Exiting..."
        exit 1
    fi
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping additional storage configuration. Reason: ADD_DEVICE_NAME is not set."
fi