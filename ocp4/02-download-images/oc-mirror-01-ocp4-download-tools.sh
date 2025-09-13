#!/bin/bash

### ---------------------------------------------------------------------------------
### Download OpenShift Client Tools
### ---------------------------------------------------------------------------------
### This script downloads and prepares essential OpenShift client tools ('oc',
### 'oc-mirror', 'butane') required for the disconnected installation workflow.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Validate Environment and Setup
### ---------------------------------------------------------------------------------
### Validate that critical environment variables from the config are set.
printf "%-8s%-80s\n" "[INFO]" "=== Validating prerequisites ==="
if [[ -z "$WORK_DIR" || -z "$PULL_SECRET_FILE" || -z "$log_dir" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set. Exiting..."
    exit 1
fi

### Extract OCP versions from the configuration.
extract_ocp_versions

### Validate that OCP versions were found.
if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    OCP_VERSION_ARRAY is empty. Check 'OCP_VERSIONS' in your config. Exiting..."
    exit 1
fi

### Determine the latest OCP version from the array.
latest_version="${OCP_VERSION_ARRAY[-1]}"
if [[ -z "$latest_version" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Failed to determine the latest OCP version from the configuration. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Display Configuration Summary
### ---------------------------------------------------------------------------------
### Print a summary of the configuration for verification.
printf "%-8s%-80s\n" "[INFO]" "=== Configuration Summary ==="
printf "%-8s%-80s\n" "[INFO]" "    Working Directory : $WORK_DIR"
printf "%-8s%-80s\n" "[INFO]" "    Tools Directory   : $TOOL_DIR"
printf "%-8s%-80s\n" "[INFO]" "    Butane URL        : $BUTANE_DOWNLOAD_URL"
printf "%-8s%-80s\n" "[INFO]" "    OCP Client (RHEL8): $OPENSHIFT_CLIENT_DOWNLOAD_URL/$latest_version/$OPENSHIFT_CLIENT_RHEL8_FILE"
printf "%-8s%-80s\n" "[INFO]" "    OCP Client (RHEL9): $OPENSHIFT_CLIENT_DOWNLOAD_URL/$latest_version/$OPENSHIFT_CLIENT_RHEL9_FILE"
printf "%-8s%-80s\n" "[INFO]" "    oc-mirror (RHEL8) : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL8_TAR"
printf "%-8s%-80s\n" "[INFO]" "    oc-mirror (RHEL9) : $OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL9_TAR"

### ---------------------------------------------------------------------------------
### Download and Prepare Tools
### ---------------------------------------------------------------------------------
### Prepare the tool directory, cleaning it first if it exists.
printf "%-8s%-80s\n" "[INFO]" "=== Preparing tool directory at '$TOOL_DIR' ==="
if [[ -d "$TOOL_DIR" ]]; then
    rm -rf "${TOOL_DIR}"/*
    printf "%-8s%-80s\n" "[INFO]" "    Cleaned existing tool directory."
else
    mkdir -p "$TOOL_DIR"
    printf "%-8s%-80s\n" "[INFO]" "    Tool directory created."
fi

### Defines a function to download a file from a URL.
download_tool() {
    local file_url="$1"
    local file_name
    file_name="$(basename "$file_url")"
    
    printf "%-8s%-80s\n" "[INFO]" "--- Downloading '$file_name'..."
    if curl -s -k -L -O "$file_url"; then
        printf "%-8s%-80s\n" "[INFO]" "    Download of '$file_name' complete."
        if [[ -f "$file_name" ]]; then
            mv "$file_name" "$TOOL_DIR/"
            printf "%-8s%-80s\n" "[INFO]" "    Moved '$file_name' to tool directory."
        else
            printf "%-8s%-80s\n" "[ERROR]" "    Downloaded file '$file_name' not found. Exiting..."
            exit 1
        fi
    else
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to download '$file_name' from '$file_url'. Exiting..."
        exit 1
    fi
}

### Download all required tool binaries.
printf "%-8s%-80s\n" "[INFO]" "=== Starting all tool downloads ==="
download_tool "$BUTANE_DOWNLOAD_URL"
download_tool "$OPENSHIFT_CLIENT_DOWNLOAD_URL/$latest_version/$OPENSHIFT_CLIENT_RHEL8_FILE"
download_tool "$OPENSHIFT_CLIENT_DOWNLOAD_URL/$latest_version/$OPENSHIFT_CLIENT_RHEL9_FILE"
download_tool "$OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL8_TAR"
download_tool "$OC_MIRROR_DOWNLOAD_URL/$OC_MIRROR_RHEL9_TAR"
printf "%-8s%-80s\n" "[INFO]" "    All tool downloads completed successfully."

### ---------------------------------------------------------------------------------
### Extract and Configure oc-mirror
### ---------------------------------------------------------------------------------

printf "%-8s%-80s\n" "[INFO]" "=== Extracting and configuring 'oc-mirror' ==="
printf "%-8s%-80s\n" "[INFO]" "    'oc-mirror' is essential for mirroring OpenShift images in disconnected environments."
printf "%-8s%-80s\n" "[INFO]" "    'oc-mirror' based on host RHEL version..."

### Detect the RHEL version of the host system.
rhel_version=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release 2>/dev/null || echo "unknown")
printf "%-8s%-80s\n" "[INFO]" "    Detected RHEL version: $rhel_version."

### Remove any existing oc-mirror binary in the current directory.
if [[ -f "./oc-mirror" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    Removing existing './oc-mirror' binary to prevent conflicts."
    rm -f oc-mirror
fi

### Extract the 'oc-mirror' binary that matches the host's RHEL version.
printf "%-8s%-80s\n" "[INFO]" "    Extracting 'oc-mirror' binary..."
if [[ "$rhel_version" == "8" ]]; then
    if [[ -f "$TOOL_DIR/$OC_MIRROR_RHEL8_TAR" ]]; then
        tar xf "$TOOL_DIR/$OC_MIRROR_RHEL8_TAR" -C ./ oc-mirror
        printf "%-8s%-80s\n" "[INFO]" "    Extracted 'oc-mirror' for RHEL 8."
    else
        printf "%-8s%-80s\n" "[ERROR]" "    RHEL 8 oc-mirror tarball not found in '$TOOL_DIR'. Exiting..."
        exit 1
    fi
elif [[ "$rhel_version" == "9" ]]; then
    if [[ -f "$TOOL_DIR/$OC_MIRROR_RHEL9_TAR" ]]; then
        tar xf "$TOOL_DIR/$OC_MIRROR_RHEL9_TAR" -C ./ oc-mirror
        printf "%-8s%-80s\n" "[INFO]" "    Extracted 'oc-mirror' for RHEL 9."
    else
        printf "%-8s%-80s\n" "[ERROR]" "    RHEL 9 oc-mirror tarball not found in '$TOOL_DIR'. Exiting..."
        exit 1
    fi
else
    printf "%-8s%-80s\n" "[ERROR]" "    Unsupported RHEL version: '$rhel_version'. Cannot extract 'oc-mirror'. Exiting..."
    exit 1
fi

### Set permissions and verify the extracted binary.
if [[ -f "./oc-mirror" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    Setting ownership and execute permissions for './oc-mirror'..."
    chown "$(whoami):$(id -gn)" ./oc-mirror
    chmod ug+x ./oc-mirror
    printf "%-8s%-80s\n" "[INFO]" "    'oc-mirror' is ready. Checking version..."
    ./oc-mirror --v2 version
else
    printf "%-8s%-80s\n" "[ERROR]" "    The './oc-mirror' binary was not found after extraction. Exiting..."
    exit 1
fi

echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Setup of OpenShift client tools completed successfully ==="
printf "%-8s%-80s\n" "[INFO]" "    Final contents of the tool directory: $TOOL_DIR"
ls -lrt "$TOOL_DIR"
echo ""