#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Additional Storage
### ---------------------------------------------------------------------------------
### This script creates a Butane configuration for an additional disk or partition
### to be used for container storage ('/var/lib/containers'). The configuration is
### converted into a MachineConfig and injected into the installer.

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
### Generate Storage Configuration
### ---------------------------------------------------------------------------------
### Check if an additional device is configured. If not, exit gracefully.

###
### Disk partitions are created on OpenShift Container Platform cluster nodes during the Red Hat Enterprise Linux CoreOS (RHCOS) installation.
### After Install:
###   Mounting separate disk for OpenShift 4 container storage
###   https://access.redhat.com/solutions/4952011
### Before Install :
###   Partitioning reference:
###   https://docs.openshift.com/container-platform/4.16/installing/installing_bare_metal/installing-bare-metal.html?extIdCarryOver=true&sc_cid=701f2000001OH6kAAG#installation-user-infra-machines-advanced_disk_installing-bare-metal
###
if [[ -n "$ADD_DEVICE_NAME" ]]; then
    echo "INFO: Additional storage device configured. Generating storage MachineConfig..."

    ### Validate required variables for this process.
    validate_non_empty "PARTITION_LABEL" "$PARTITION_LABEL"
    validate_non_empty "FILESYSTEM_PATH" "$FILESYSTEM_PATH"
    validate_non_empty "BUTANE_BU_DIR" "$BUTANE_BU_DIR"
    validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

    ### Check if the required directories exist.
    if [[ ! -d "$BUTANE_BU_DIR" || ! -d "$ADDITIONAL_MANIFEST" ]]; then
        echo "ERROR: Required directories for MachineConfig generation do not exist." >&2
        echo "INFO: Please ensure you have run previous scripts to create these directories." >&2
        exit 1
    fi

    ### Determine the type of device configuration (partition or direct).
    if [[ "$ADD_DEVICE_TYPE" == "PARTITION" ]]; then
        echo "INFO: Configuring additional storage as a partition on device '$ADD_DEVICE_NAME'."
        validate_non_empty "PARTITION_START_MIB" "$PARTITION_START_MIB"
        validate_non_empty "PARTITION_SIZE_MIB" "$PARTITION_SIZE_MIB"
        validate_non_empty "PARTITION_NUMBER" "$PARTITION_NUMBER"

        for role in "master" "worker"; do    
            echo "INFO: -> Creating Butane config for '$role' nodes."
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
            echo "INFO: -> Transpiling Butane file for '$role' nodes."
            ./butane "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu" -o "$ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml"
            echo "INFO: -> Successfully created MachineConfig for '$role' nodes."
        done
    elif [[ "$ADD_DEVICE_TYPE" == "DIRECT" ]]; then
        echo "INFO: Configuring additional storage as a direct device '$ADD_DEVICE_NAME'."
        for role in "master" "worker"; do          
            echo "INFO: -> Creating Butane config for '$role' nodes."
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
            echo "INFO: -> Transpiling Butane file for '$role' nodes."
            ./butane "$BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu" -o "$ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml"
            echo "INFO: -> Successfully created MachineConfig for '$role' nodes."
        done
    else
        echo "ERROR: Invalid ADD_DEVICE_TYPE '$ADD_DEVICE_TYPE'. Must be 'PARTITION' or 'DIRECT'." >&2
        exit 1
    fi
    echo "--- Storage configuration completed successfully."
else
    echo "INFO: No additional storage device specified. Skipping this step."
    echo "--- Script execution finished without making changes."
fi