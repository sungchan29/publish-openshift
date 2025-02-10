#!/bin/bash

PROJECT_NAME="scm-manager"
NFS_BASE_PATH="/data/exports/ocp"

MOUNT_BASE_PATH="/mnt/nfs" # Base mount directory on RHEL

# Retrieve OpenShift project UID
echo "Fetching OpenShift UID for project: $PROJECT_NAME"
PROJECT_UID=$(oc get project $PROJECT_NAME -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' | cut -d'/' -f1)

if [ -z "$PROJECT_UID" ]; then
    echo "Failed to fetch project UID."
    exit 1
fi

echo "Project UID: $PROJECT_UID"

# Get list of all PVCs in the project
PVC_LIST=$(oc get pvc -n $PROJECT_NAME -o jsonpath='{.items[*].metadata.name}')

# Check if there are any PVCs
if [ -z "$PVC_LIST" ]; then
    echo "No PVCs found in project: $PROJECT_NAME"
    exit 0
fi

echo "Checking PVCs in project: $PROJECT_NAME"

# Iterate through each PVC and retrieve its bound PV
for PVC in $PVC_LIST; do
    PV_NAME=$(oc get pvc $PVC -n $PROJECT_NAME -o jsonpath='{.spec.volumeName}')

    if [ -z "$PV_NAME" ]; then
        echo "PVC: $PVC is not bound to any PV."
        continue
    fi

    # Get NFS server and path from the PV
    NFS_SERVER=$(oc get pv $PV_NAME -o jsonpath='{.spec.nfs.server}')
    NFS_PATH=$(oc get pv $PV_NAME -o jsonpath='{.spec.nfs.path}')

    if [ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]; then
        echo "PV: $PV_NAME does not have NFS configuration."
        continue
    fi

    echo "Mounting NFS for PVC: $PVC -> PV: $PV_NAME"
    echo "NFS Server: $NFS_SERVER, Path: $NFS_PATH"
    
    # Check if NFS_PATH contains NFS_BASE_PATH
    if [[ "$NFS_PATH" == "$NFS_BASE_PATH"* ]]; then
        SUB_PATH="${NFS_PATH#"$NFS_BASE_PATH"/}"  # Remove base path including the trailing slash
        echo "Extracted sub-directory path: $SUB_PATH"
    else
        echo "NFS_PATH does not contain NFS_BASE_PATH."
    fi

    # Mount the NFS volume
    if [[ -n "$NFS_BASE_PATH" ]]; then
        # Define local mount path
        LOCAL_MOUNT_PATH="${MOUNT_BASE_PATH}"

        if ! mountpoint -q $LOCAL_MOUNT_PATH; then
            mkdir -p $LOCAL_MOUNT_PATH
            mount -t nfs $NFS_SERVER:$NFS_BASE_PATH $LOCAL_MOUNT_PATH
        fi

        mkdir -p $LOCAL_MOUNT_PATH/$SUB_PATH
        chown -R $PROJECT_UID $LOCAL_MOUNT_PATH/$SUB_PATH
    else
        # Define local mount path
       LOCAL_MOUNT_PATH="${MOUNT_BASE_PATH}/${PVC}"

        mkdir -p $LOCAL_MOUNT_PATH
        mount -t nfs $NFS_SERVER:$NFS_PATH $LOCAL_MOUNT_PATH

        chown -R $PROJECT_UID $LOCAL_MOUNT_PATH

        # Unmount NAS
        echo "Unmounting NAS..."
        sudo umount $MOUNT_PATH || { echo "Failed to unmount NFS"; exit 1; }
    fi

    # Check if mount was successful
    if mountpoint -q $LOCAL_MOUNT_PATH; then
        echo "Successfully mounted $NFS_SERVER:$NFS_PATH to $LOCAL_MOUNT_PATH"
    else
        echo "Failed to mount $NFS_SERVER:$NFS_PATH to $LOCAL_MOUNT_PATH"
    fi
done

if [[ -n "$NFS_BASE_PATH"]]; then
    # Unmount NAS
    echo "Unmounting NAS..."
    sudo umount $MOUNT_PATH || { echo "Failed to unmount NFS"; exit 1; }
fi


echo "OpenShift storage setup completed successfully."
