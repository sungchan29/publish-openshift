#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

echo "-----------------------------"
echo "                   WORK_DIR : $WORK_DIR"
echo "                   TOOL_DIR : $TOOL_DIR"
echo "        BUTANE_DOWNLOAD_URL : $BUTANE_DOWNLOAD_URL"
echo "OPENSHIFT_CLIENT_RHEL8_FILE : $OPENSHIFT_CLIENT_DOWNLOAD_URL/$OPENSHIFT_CLIENT_RHEL8_FILE"
echo "OPENSHIFT_CLIENT_RHEL9_FILE : $OPENSHIFT_CLIENT_DOWNLOAD_URL/$OPENSHIFT_CLIENT_RHEL9_FILE"
echo "        OC_MIRROR_RHEL8_TAR : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL8_TAR"
echo "        OC_MIRROR_RHEL9_TAR : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL9_TAR"
echo "-----------------------------"

### Define and prepare the download directory
### Check if the directory for downloading tools exists and clean it up before proceeding
if [[ -d "$TOOL_DIR" ]]; then
    rm -rf "${TOOL_DIR}"/*
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create directory 'TOOL_DIR'. Exiting..."
        exit 1
    fi
    echo "[INFO] Cleaning up existing files in 'TOOL_DIR'..."
else
    mkdir -p "$TOOL_DIR"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create directory 'TOOL_DIR'. Exiting..."
        exit 1
    fi
fi

### Download butane binary
### Define a function to handle the downloading of openshift tool binaries
download_tool() {
    local file=$1  # The tarball filename (RHEL8 or RHEL9 version)
    echo "[INFO] Downloading openshift tool from $file..."
    curl -k -O "$file"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to download $file. Exiting..."
        exit 1
    fi
}

### Extract the oc-mirror binary based on the RHEL version
### Depending on the RHEL version, extract the appropriate tarball for oc-mirror
extract_oc_mirror() {
    local file=$1
    local tool=$2
    if [[ -f "$file" ]]; then
        echo "[INFO] Extracting oc-mirror from $file..."
        tar xvf "$file" -C ./ $tool
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to extract $file. Exiting..."
            exit 1
        fi
    else
        echo "ERROR: $file not found. Exiting..."
        exit 1
    fi
}

### Move downloaded files to the designated directory
### Move the downloaded tarballs into the tools directory for proper storage
move_files() {
    local file=$1
    if [[ -f "$file" ]]; then
        mv "$file" "$TOOL_DIR/"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to move $file to $TOOL_DIR. Exiting..."
            exit 1
        fi
    fi
}


### Download the oc-mirror binaries for RHEL 8 and RHEL 9 if they are set in the configuration
if [[ -n "$BUTANE_DOWNLOAD_URL" ]]; then
    download_tool "$BUTANE_DOWNLOAD_URL"
    move_files "butane"
fi
if [[ -n "$OPENSHIFT_CLIENT_RHEL8_FILE" ]]; then
    download_tool "$OPENSHIFT_CLIENT_DOWNLOAD_URL/$OPENSHIFT_CLIENT_RHEL8_FILE"
    move_files "$OPENSHIFT_CLIENT_RHEL8_FILE"
fi
if [[ -n "$OPENSHIFT_CLIENT_RHEL9_FILE" ]]; then
    download_tool "$OPENSHIFT_CLIENT_DOWNLOAD_URL/$OPENSHIFT_CLIENT_RHEL9_FILE"
    move_files "$OPENSHIFT_CLIENT_RHEL9_FILE"
fi

if [[ -n "$OC_MIRROR_RHEL8_TAR" ]]; then
    download_tool "$OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL8_TAR"
    move_files "$OC_MIRROR_RHEL8_TAR"
fi
if [[ -n "$OC_MIRROR_RHEL9_TAR" ]]; then
    download_tool "$OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL9_TAR"
    move_files "$OC_MIRROR_RHEL9_TAR"
fi

### Determine the RHEL version of the system
### Extract the RHEL version from `/etc/os-release` to determine which version of oc-mirror to extract
rhel_version=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release 2>/dev/null)
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to determine RHEL version from /etc/os-release. Exiting..."
    exit 1
fi

### Remove any existing oc-mirror binary before extracting the new one
### If an old `oc-mirror` binary exists, remove it to avoid conflicts with the new version
if [[ -f "./oc-mirror" ]]; then
    echo "[INFO] Removing existing oc-mirror binary..."
    rm -f oc-mirror
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to remove existing oc-mirror binary. Exiting..."
        exit 1
    fi
fi

### Extract the correct `oc-mirror` binary based on the RHEL version detected
if [[ "$rhel_version" == "8" ]]; then
    if [[ -f "$TOOL_DIR/$OC_MIRROR_RHEL8_TAR" ]]; then
        extract_oc_mirror "$TOOL_DIR/$OC_MIRROR_RHEL8_TAR" "oc-mirror"
    fi
elif [[ "$rhel_version" == "9" ]]; then
    if [[ -f "$TOOL_DIR/$OC_MIRROR_RHEL9_TAR" ]]; then
        extract_oc_mirror "$TOOL_DIR/$OC_MIRROR_RHEL9_TAR" "oc-mirror"
    fi
else
    echo "ERROR: Unsupported RHEL version: 'rhel_version'. Exiting..."
    exit 1
fi

### Set correct ownership and execute permissions for openshift tool binary
if [[ -f "./oc-mirror" ]]; then
    echo "[INFO] Setting ownership and permissions for oc-mirror..."
    chown "$(whoami):$(id -gn)" ./oc-mirror
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to set ownership for oc-mirror. Exiting..."
        exit 1
    fi
    chmod ug+x ./oc-mirror
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to set execute permissions for oc-mirror. Exiting..."
        exit 1
    fi
else
    echo "ERROR: oc-mirror binary not found after extraction. Exiting..."
    exit 1
fi

### Indicate that the setup process has completed successfully
echo "[INFO] Setup completed successfully."
echo ""
echo "[INFO] Listing files in $TOOL_DIR :"
ls -lrt $TOOL_DIR
