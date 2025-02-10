#!/bin/bash

# Define the OpenShift project name
PROJECT_NAME="scm-manager"

# Base directory for NFS storage provided by the storage team
NFS_BASE_PATH="/data/exports/ocp"

# Local mount directory for NFS storage on the RHEL system
MOUNT_PATH="/mnt/nfs"

# Retrieve OpenShift project UID
echo "[INFO] Fetching OpenShift UID for project: $PROJECT_NAME"
PROJECT_UID=$(oc get project $PROJECT_NAME -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' | cut -d'/' -f1)

# Exit if UID retrieval fails
if [ -z "$PROJECT_UID" ]; then
    echo "[ERROR] Failed to fetch project UID." >&2
    exit 1
fi

echo "[INFO] Project UID: $PROJECT_UID"

# Get the list of all PVCs in the project
PVC_LIST=$(oc get pvc -n $PROJECT_NAME -o jsonpath='{.items[*].metadata.name}')

# Check if any PVCs exist
if [ -z "$PVC_LIST" ]; then
    echo "[INFO] No PVCs found in project: $PROJECT_NAME"
    exit 0
fi

echo "[INFO] Checking PVCs in project: $PROJECT_NAME"

# Define local mount path for individual PVC
mkdir -p $MOUNT_PATH

# Iterate through each PVC to retrieve its bound PV
for PVC in $PVC_LIST; do
    PV_NAME=$(oc get pvc $PVC -n $PROJECT_NAME -o jsonpath='{.spec.volumeName}')

    # Skip PVCs that are not bound to any PV
    if [ -z "$PV_NAME" ]; then
        echo "[INFO] PVC: $PVC is not bound to any PV."
        continue
    fi

    # Retrieve the NFS server and path from the PV
    NFS_SERVER=$(oc get pv $PV_NAME -o jsonpath='{.spec.nfs.server}')
    NFS_PATH=$(oc get pv $PV_NAME -o jsonpath='{.spec.nfs.path}')

    # Skip PVs without NFS configuration
    if [ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]; then
        echo "[ERROR] PV: $PV_NAME does not have NFS configuration." >&2
        continue
    fi

    # Mount the NFS volume
    if [[ -n "$NFS_BASE_PATH" ]]; then
        # Extract subdirectory path if NFS_PATH contains NFS_BASE_PATH
        SUB_PATH=""
        if [[ "$NFS_PATH" == "$NFS_BASE_PATH"* ]]; then
            SUB_PATH="${NFS_PATH#"$NFS_BASE_PATH"/}"  # Remove base path including the trailing slash
            echo "[INFO] Provided NFS base directory: $NFS_BASE_PATH"
            echo "[INFO] Derived subdirectory from the provided NFS base: $SUB_PATH"
        else
            echo "[ERROR] NFS_PATH does not match the provided NFS base directory." >&2
            continue
        fi

        echo "[INFO] Mounting $MOUNT_PATH..."
        mount -t nfs $NFS_SERVER:$NFS_BASE_PATH $MOUNT_PATH
            
        # Verify if the mount was successful
        if mountpoint -q $MOUNT_PATH; then
            echo "[INFO] Successfully mounted $NFS_SERVER:$NFS_PATH to $MOUNT_PATH"
        else
            echo "[ERROR] Failed to mount $NFS_SERVER:$NFS_PATH to $MOUNT_PATH" >&2
        fi

        # Create the subdirectory and set ownership
        mkdir -p $MOUNT_PATH/$SUB_PATH
        chown -R $PROJECT_UID $MOUNT_PATH/$SUB_PATH
    else
        echo "[INFO] Mounting $MOUNT_PATH..."
        mount -t nfs $NFS_SERVER:$NFS_PATH $MOUNT_PATH

        # Verify if the mount was successful
        if mountpoint -q $MOUNT_PATH; then
            echo "[INFO] Successfully mounted $NFS_SERVER:$NFS_PATH to $MOUNT_PATH"
            # Set correct ownership
            chown -R $PROJECT_UID $MOUNT_PATH
        else
            echo "[ERROR] Failed to mount $NFS_SERVER:$NFS_PATH to $MOUNT_PATH" >&2
        fi
    fi

    echo "[INFO] Running command: ls -al $MOUNT_PATH"
    df -h $MOUNT_PATH
    echo "[INFO] Running command: ls -al $MOUNT_PATH"
    ls -al $MOUNT_PATH

    # Unmount NAS
    echo "[INFO] Unmounting NAS..."
    umount $MOUNT_PATH || { echo "[ERROR] Failed to unmount NFS" >&2; }
done

echo "[INFO] OpenShift storage setup completed successfully."