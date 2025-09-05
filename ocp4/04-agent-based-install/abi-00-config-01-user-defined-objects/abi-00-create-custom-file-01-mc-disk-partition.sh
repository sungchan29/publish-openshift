#!/bin/bash

### Enable strict mode
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

butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

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
    ### Validate required variables
    validate_non_empty "PARTITION_LABEL"     "$PARTITION_LABEL"
    validate_non_empty "FILESYSTEM_PATH"     "$FILESYSTEM_PATH"
    validate_non_empty "BUTANE_BU_DIR"       "$BUTANE_BU_DIR"
    validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

    if [[ "$ADD_DEVICE_TYPE" == "PARTITION" ]]; then
        validate_non_empty "PARTITION_START_MIB" "$PARTITION_START_MIB"
        validate_non_empty "PARTITION_SIZE_MIB"  "$PARTITION_SIZE_MIB"
        validate_non_empty "PARTITION_NUMBER"    "$PARTITION_NUMBER"

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
    elif [[ "$ADD_DEVICE_TYPE" == "DIRECT" ]]; then
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
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi