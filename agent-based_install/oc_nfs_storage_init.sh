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

  # Define local mount path
  LOCAL_MOUNT_PATH="${MOUNT_BASE_PATH}/${PVC}"

  echo "Mounting NFS for PVC: $PVC -> PV: $PV_NAME"
  echo "NFS Server: $NFS_SERVER, Path: $NFS_PATH"

  # Create local mount directory
  mkdir -p $LOCAL_MOUNT_PATH

  # Mount the NFS volume
  if [[ -n "$NFS_BASE_PATH"]]; then
    mount -t nfs $NFS_SERVER:$NFS_BASE_PATH $LOCAL_MOUNT_PATH
  else
    mount -t nfs $NFS_SERVER:$NFS_PATH $LOCAL_MOUNT_PATH
  fi

  # Check if mount was successful
  if mountpoint -q $LOCAL_MOUNT_PATH; then
    echo "Successfully mounted $NFS_SERVER:$NFS_PATH to $LOCAL_MOUNT_PATH"
  else
    echo "Failed to mount $NFS_SERVER:$NFS_PATH to $LOCAL_MOUNT_PATH"
  fi
done

 

# Mount NFS and create the directory
echo "Mounting NAS..."
sudo mount -t nfs $NFS_SERVER:$NFS_PATH $MOUNT_PATH || { echo "Failed to mount NFS"; exit 1; }

echo "Creating directory and setting permissions..."
sudo mkdir -p $MOUNT_PATH                # Create directory if not exists
sudo chown -R $PROJECT_UID:$PROJECT_UID $MOUNT_PATH  # Change ownership to OpenShift UID
sudo chmod -R 770 $MOUNT_PATH             # Set appropriate permissions

# Unmount NAS
echo "Unmounting NAS..."
sudo umount $MOUNT_PATH || { echo "Failed to unmount NFS"; exit 1; }

echo "OpenShift storage setup completed successfully."
