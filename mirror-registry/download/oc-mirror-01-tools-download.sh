#!/bin/bash

### Source the configuration file and validate its existence
### This will load variables defined in the configuration script `oc-mirror-00-config-setup.sh`
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"  # Import configuration variables from the setup script

### Validate required environment variables
### Ensure that the OC_MIRROR_RHEL8_TAR and OC_MIRROR_RHEL9_TAR variables are set in the configuration file
if [[ -z "${OC_MIRROR_RHEL8_TAR}" ]]; then
    echo "ERROR: 'OC_MIRROR_RHEL8_TAR' variable is not set. Exiting..."
    exit 1
fi
if [[ -z "${OC_MIRROR_RHEL9_TAR}" ]]; then
    echo "ERROR: 'OC_MIRROR_RHEL9_TAR' variable is not set. Exiting..."
    exit 1
fi

echo "---------------------"
echo "           WORK_DIR : $WORK_DIR"
echo "           TOOL_DIR : $TOOL_DIR"
echo "OC_MIRROR_RHEL8_TAR : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL8_TAR"
echo "OC_MIRROR_RHEL9_TAR : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL9_TAR"
echo "BUTANE_DOWNLOAD_URL : $BUTANE_DOWNLOAD_URL"
echo "---------------------"

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
### Fetch the latest `butane` binary, which is used to generate Ignition files for OpenShift installation
echo "[INFO] Downloading butane..."
curl -k -O "$BUTANE_DOWNLOAD_URL"
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to download butane. Exiting..."
    exit 1
fi

### Move the downloaded `butane` binary into the tools directory
mv butane "$TOOL_DIR/"
if [[ $? -ne 0 ]]; then
    echo "ERROR: . Exiting..."
    exit 1
fi

### Download oc-mirror for RHEL 8 and RHEL 9
### Define a function to handle the downloading of oc-mirror binaries
download_oc_mirror() {
    local file=$1  # The tarball filename (RHEL8 or RHEL9 version)
    local url="$OC_MIRROR_DOWNLOAD_URL/$file"
    echo "[INFO] Downloading oc-mirror from $url..."
    curl -k -O "$url"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to download $file. Exiting..."
        exit 1
    fi
}

### Download the oc-mirror binaries for RHEL 8 and RHEL 9 if they are set in the configuration
if [[ -n "$OC_MIRROR_RHEL8_TAR" ]]; then
    download_oc_mirror "$OC_MIRROR_RHEL8_TAR"
fi
if [[ -n "$OC_MIRROR_RHEL9_TAR" ]]; then
    download_oc_mirror "$OC_MIRROR_RHEL9_TAR"
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
if [[ -f oc-mirror ]]; then
    echo "[INFO] Removing existing oc-mirror binary..."
    rm -f oc-mirror
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to remove existing oc-mirror binary. Exiting..."
        exit 1
    fi
fi

### Extract the oc-mirror binary based on the RHEL version
### Depending on the RHEL version, extract the appropriate tarball for oc-mirror
extract_oc_mirror() {
    local file=$1  # The tarball filename (either RHEL 8 or RHEL 9)
    if [[ -f "$file" ]]; then
        echo "[INFO] Extracting oc-mirror from $file..."
        tar xvf "$file"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to extract $file. Exiting..."
            exit 1
        fi
    else
        echo "ERROR: $file not found. Exiting..."
        exit 1
    fi
}

### Extract the correct `oc-mirror` binary based on the RHEL version detected
if [[ "$rhel_version" == "8" ]]; then
    extract_oc_mirror "$OC_MIRROR_RHEL8_TAR"
elif [[ "$rhel_version" == "9" ]]; then
    extract_oc_mirror "$OC_MIRROR_RHEL9_TAR"
else
    echo "ERROR: Unsupported RHEL version: 'rhel_version'. Exiting..."
    exit 1
fi

### Move downloaded files to the designated directory
### Move the downloaded tarballs into the tools directory for proper storage
move_files() {
    local file=$1  # The file to be moved
    if [[ -f "$file" ]]; then
        mv "$file" "$TOOL_DIR/"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to move $file to $TOOL_DIR. Exiting..."
            exit 1
        fi
    fi
}

### Move the downloaded tarballs to the tools directory
move_files "$OC_MIRROR_RHEL8_TAR"
move_files "$OC_MIRROR_RHEL9_TAR"

### Set correct ownership and execute permissions for oc-mirror binary
### After extraction, set the ownership and permissions for the `oc-mirror` binary so that it can be executed
if [[ -f oc-mirror ]]; then
    echo "[INFO] Setting ownership and permissions for oc-mirror..."
    chown "$(whoami):$(id -gn)" oc-mirror
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to set ownership for oc-mirror. Exiting..."
        exit 1
    fi
    chmod ug+x oc-mirror
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
echo "Listing files in $TOOL_DIR :"
ls -lrt $TOOL_DIR