#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Validate OCP_VERSION

butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

### Disk partitions are created on OpenShift Container Platform cluster nodes during the Red Hat Enterprise Linux CoreOS (RHCOS) installation.
### After Install:
###   Mounting separate disk for OpenShift 4 container storage
###   https://access.redhat.com/solutions/4952011
### Before Install :
###   Partitioning reference:
###   https://docs.openshift.com/container-platform/4.16/installing/installing_bare_metal/installing-bare-metal.html?extIdCarryOver=true&sc_cid=701f2000001OH6kAAG#installation-user-infra-machines-advanced_disk_installing-bare-metal
if [[ -n "$ADD_DEVICE_NAME" ]]; then
    ### Validate required variables
    unset required_vars
    declare -a required_vars=("PARTITION_LABEL" "FILESYSTEM_PATH" "BUTANE_BU_DIR" "ADDITIONAL_MANIFEST")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "Error: $var is not defined or empty in $config_file."
            exit 1
        fi
    done

    if [[ "$ADD_DEVICE_TYPE" == "PARTITION" ]]; then
        unset required_vars
        declare -a required_vars=("PARTITION_START_MIB" "PARTITION_SIZE_MIB" "PARTITION_NUMBER")
        for var in "${required_vars[@]}"; do
            if [[ -z "${!var}" ]]; then
                echo "Error: $var is not defined or empty in $config_file."
                exit 1
            fi
        done

        for role in "master" "worker"; do    
cat << EOF > $BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu
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
            ./butane $BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu -o $ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml
        done
    else
        for role in "master" "worker"; do          
cat << EOF > $BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu
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
            ./butane $BUTANE_BU_DIR/98-${role}-${PARTITION_LABEL}.bu -o $ADDITIONAL_MANIFEST/98-${role}-${PARTITION_LABEL}.yaml
        done
    fi
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch MachineConfig(Disk partition)."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi