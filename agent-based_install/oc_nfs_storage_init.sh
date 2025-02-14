#!/bin/bash

# Local mount directory for NFS storage on the RHEL system
MOUNT_PATH="/mnt/nfs"

API_SERVER=""

################
### Function ###
################

usage() {
    echo
    echo "Usage: $0 " '-u <username> [--project="<project> ... <project>"] [<api server>]'
    echo
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help | -h)
            help="true"
            shift
            ;;
        -u)
            if [[ -n "$2" && "$2" != -* ]]; then
                username="$2"
                shift 2
            else
                echo "[ERROR] -u option requires a username."
                exit 1
            fi
            ;;
        --project=*)
            projects="${1#*=}"
            shift
            ;;
        # Reject all undefined options starting with '-'
        -*)
            echo "[ERROR] Invalid option: $1"
            exit 1
            ;;
        # Assign the first non-option argument as the API server
        *)
            if [[ -z "$apiserver" ]]; then
                apiserver="$1"
            else
                echo "[ERROR] Multiple API server values provided: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ "true" = ${help} ]]; then
    usage
fi

### Define local mount path for individual PVC
mkdir -p $MOUNT_PATH

### Check utils(oc) ###
echo "========================================"
echo "[INFO] Checking if OpenShift CLI (oc) is installed..."
if [[ -n ${PATH_UTIL} ]]; then
    export PATH="${PATH_UTIL}:${PATH}"
fi

which oc > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo "[ERROR] The 'oc' command was not found."
    echo "[ERROR] Please ensure OpenShift CLI (oc) is installed and available in the system PATH."
    echo "========================================"
    exit 1
fi
echo "[INFO] OpenShift CLI (oc) is available."
echo "========================================"

### oc logout ###
echo "[INFO] Checking existing OpenShift session..."
USER_TOKEN=$(oc config view --minify -o jsonpath='{.users[].user.token}' 2>/dev/null)
if [[ -n "${USER_TOKEN}" ]]; then
    echo "[INFO] Logging out from existing OpenShift session..."
    oc logout
    echo "[INFO] Successfully logged out from previous session."
fi
echo "========================================"

### Log in to your server ###
echo "[INFO] Attempting to log in to OpenShift with user: $username"
if [[ -z "$username" ]]; then
    usage
else
    if [[ -z "$password" ]]; then
        oc login -u $username $apiserver --insecure-skip-tls-verify
    else
        oc login -u ${username} -p ${password} ${apiserver} --insecure-skip-tls-verify
    fi
fi

### Check login success ###
if [[ $? -ne 0 ]]; then
    echo "[ERROR] OpenShift login failed."
    echo "[ERROR] Please check your credentials and API server address."
    echo "========================================"
    exit 1
fi
echo "[INFO] OpenShift login successful."
echo "========================================"

if [[ -z "$projects" ]]; then
    ### Get OpenShift project name from user input
    read -p "Enter OpenShift project name: " projects
    echo "========================================"
fi

for project_name in $projects
do
    ### Get NFS base path from user input (optional)
    echo "###"
    echo "### Prjoject: $project_name"
    echo "###"
    echo "========================================"
    echo "[INFO] Enter the NFS base path for project '$project_name'."
    echo "[INFO] - If an empty value ('') is entered, permissions will be modified directly on the NFS path set in the PV."
    echo "[INFO] - If a specific path is entered, the NFS path configured in the PV must be structured as a subdirectory under the specified path."
    echo "[INFO]   Required directories will be automatically created based on the NFS path defined in the PV."

    ### Read NFS_BASE_PATH from user input and normalize it
    read -p "NFS Base Path (press Enter to use default ''): " NFS_BASE_PATH
    NFS_BASE_PATH=${NFS_BASE_PATH:-""}  # Default to empty string if not provided
    NFS_BASE_PATH="${NFS_BASE_PATH%/}"  # Remove trailing slash if exists
    echo "========================================"

    ### Retrieve OpenShift project UID
    echo "[INFO] Fetching OpenShift UID for project: $project_name"
    PROJECT_UID=$(oc get project $project_name -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' | cut -d'/' -f1)

    ### Exit if UID retrieval fails
    if [ -z "$PROJECT_UID" ]; then
        echo "[ERROR] Failed to fetch project UID."
        echo "========================================"
        exit 1
    fi
    echo "[INFO] Project UID: $PROJECT_UID"
    echo "========================================"

    ### Get the list of all PVCs in the project
    echo "[INFO] Fetching PVC list for project: $project_name"
    PVC_LIST=$(oc get pvc -n $project_name -o jsonpath='{.items[*].metadata.name}')

    ### Check if any PVCs exist
    if [ -z "$PVC_LIST" ]; then
        echo "[INFO] No PVCs found in project: $project_name"
        echo "========================================"
        exit 0
    fi

    ### Iterate through each PVC to retrieve its bound PV
    echo "[INFO] Checking PVCs in project: $project_name"
    for PVC in $PVC_LIST; do
        PV_NAME=$(oc -n $project_name get pvc $PVC -o jsonpath='{.spec.volumeName}')

        ### Skip PVCs that are not bound to any PV
        if [ -z "$PV_NAME" ]; then
            echo "[INFO] PVC: $PVC is not bound to any PV."
            continue
        fi

        ### Retrieve the NFS server and path from the PV
        NFS_SERVER=$(oc -n $project_name get pv $PV_NAME -o jsonpath='{.spec.nfs.server}')
        NFS_PATH=$(oc -n $project_name get pv $PV_NAME -o jsonpath='{.spec.nfs.path}')

        ### Skip PVs without NFS configuration
        if [ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]; then
            echo "[ERROR] PV: $PV_NAME does not have NFS configuration."
            echo "========================================"
            continue
        fi

        echo "[INFO] Processing PV: $PV_NAME"
        echo "[INFO] NFS Server: $NFS_SERVER"
        echo "[INFO] NFS Path: $NFS_PATH"

        ### Mount the NFS volume
        echo "[INFO] Mounting NFS storage..."
        if [[ -n "$NFS_BASE_PATH" ]]; then
            ### Extract subdirectory path if NFS_PATH contains NFS_BASE_PATH
            SUB_PATH=""
            if [[ "$NFS_PATH" == "$NFS_BASE_PATH"* ]]; then
                SUB_PATH="${NFS_PATH#"$NFS_BASE_PATH"/}"
                echo "[INFO] Derived subdirectory: $SUB_PATH"
            else
                echo "[ERROR] NFS_BASE_PATH does not match the provided NFS base directory."
                echo "========================================"
                continue
            fi
            mount -t nfs $NFS_SERVER:$NFS_BASE_PATH $MOUNT_PATH
            mkdir -p $MOUNT_PATH/$SUB_PATH
            chown -R $PROJECT_UID $MOUNT_PATH/$SUB_PATH
        else
            mount -t nfs $NFS_SERVER:$NFS_PATH $MOUNT_PATH
            chown -R $PROJECT_UID $MOUNT_PATH
        fi

        echo "[INFO] Running df -h on mounted path:"
        df -h $MOUNT_PATH
        echo "[INFO] Listing contents of mounted path:"
        ls -al $MOUNT_PATH

        ### Unmount NAS
        echo "[INFO] Unmounting NAS..."
        umount $MOUNT_PATH || { echo "[ERROR] Failed to unmount NFS"; }
        echo "========================================"
    done
done

echo "[INFO] OpenShift storage setup completed successfully."
echo "========================================"

### Log out from OpenShift
echo "[INFO] Logging out from OpenShift..."
oc logout

### Check logout success
if [[ $? -ne 0 ]]; then
    echo "[WARNING] OpenShift logout may have failed."
else
    echo "[INFO] Successfully logged out from OpenShift."
fi
echo "========================================"