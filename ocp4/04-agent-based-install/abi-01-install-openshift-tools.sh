#!/bin/bash

### ---------------------------------------------------------------------------------
### Setup Script for Agent-Based Installation
### ---------------------------------------------------------------------------------
### This script prepares the necessary binaries ('oc', 'openshift-install', 'butane')
### and configuration files for an OpenShift Agent-Based Installation (ABI) in a
### disconnected environment.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
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
validate_non_empty "LOCAL_REPOSITORY_NAME" "$LOCAL_REPOSITORY_NAME"
validate_file "$PULL_SECRET"
validate_file "$OPENSHIFT_CLIENT_TAR_FILE"
validate_file "$BUTANE_PATH"

### ---------------------------------------------------------------------------------
### Binary Cleanup
### ---------------------------------------------------------------------------------
### Clean up any previously extracted binaries to ensure a fresh start.
printf "%-8s%-80s\n" "[INFO]" "=== Cleaning up previous installation binaries. ==="
for binary in oc openshift-install butane; do
    if [[ -f "./$binary" ]]; then
        ### Check if the binary is currently in use before attempting to delete it.
        if lsof "./$binary" >/dev/null 2>&1; then
            printf "%-8s%-80s\n" "[WARN]" "--- The '$binary' binary is currently in use. Skipping removal."
        else
            printf "%-8s%-80s\n" "[INFO]" "--- Removing old './$binary' binary."
            rm -f "./$binary"
        fi
    fi
done

### ---------------------------------------------------------------------------------
### Binary Extraction and Installation
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Preparing Installation Binaries. ==="
### 1. Extract 'oc' Binary
printf "%-8s%-80s\n" "[INFO]" "--- Extracting 'oc' client from '$OPENSHIFT_CLIENT_TAR_FILE'..."
tar xvf "$OPENSHIFT_CLIENT_TAR_FILE" -C "./" oc > /dev/null
printf "%-8s%-80s\n" "[INFO]" "    -- Setting execute permissions for './oc'..."
chmod ug+x ./oc > /dev/null

### 2. Install Bash Completion (Optional)
printf "%-8s%-80s\n" "[INFO]" "--- Generating 'oc' bash completion..."
./oc completion bash > oc_bash_completion

# Check if the system-wide completion directory exists
if [[ -d "/etc/bash_completion.d" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    -- Found system directory: /etc/bash_completion.d"

    # [NEW] Check for write permission (i.e., if running as root)
    if [[ $EUID -eq 0 ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    -- Running as root. Installing system-wide completion..."
        \cp -f ./oc_bash_completion /etc/bash_completion.d/oc_completion
        printf "%-8s%-80s\n" "[INFO]" "    -- 'oc' bash completion installed system-wide."
    else
        # Not root, so we skip the copy
        printf "%-8s%-80s\n" "[WARN]" "    -- Not running as root. Skipping system-wide installation."
        printf "%-8s%-80s\n" "[INFO]" "    -- To enable completion for this session, run:"
        printf "%-8s%-80s\n" ""       "       source ./oc_bash_completion"
    fi
else
    # The directory doesn't exist
    printf "%-8s%-80s\n" "[WARN]" "    -- Directory /etc/bash_completion.d not found. Skipping system-wide installation."
    printf "%-8s%-80s\n" "[INFO]" "    -- To enable completion for this session, run:"
    printf "%-8s%-80s\n" ""       "       source ./oc_bash_completion"
fi

### 3. Create 'ImageDigestMirrorSet' Manifest
printf "%-8s%-80s\n" "[INFO]" "--- Creating ImageDigestMirrorSet manifest (idms-oc-mirror.yaml)..."
### This manifest tells 'oc' where to find mirrored images in the disconnected registry.
cat << EOF > ./idms-oc-mirror.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release-images
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors:
    - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
if [[ ! -f "./idms-oc-mirror.yaml" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to create 'idms-oc-mirror.yaml'. Exiting..."
    exit 1
fi

### 4. Extract 'openshift-install' Binary
printf "%-8s%-80s\n" "[INFO]" "--- Extracting 'openshift-install' binary from the release image..."
if [[ -f ./oc ]] && [[ -f ./idms-oc-mirror.yaml ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    -- Pulling from: '$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64'..."
    ./oc adm release extract -a "$PULL_SECRET" --insecure=true --idms-file='./idms-oc-mirror.yaml' --command=openshift-install "$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"

    if [[ ! -f ./openshift-install ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       'openshift-install' binary not found after extraction. Verify mirror registry and pull secret. Exiting..."
        exit 1
    fi
    printf "%-8s%-80s\n" "[INFO]" "    -- Setting execute permissions for 'openshift-install'..."
    chmod ug+x ./openshift-install > /dev/null
    if ! ./openshift-install version >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[ERROR]" "       The extracted 'openshift-install' binary is not executable. Exiting..."
        exit 1
    fi
else
    printf "%-8s%-80s\n" "[ERROR]" "    Prerequisites ('./oc' or './idms-oc-mirror.yaml') not found. Exiting..."
    exit 1
fi

### 5. Copy 'butane' Binary
printf "%-8s%-80s\n" "[INFO]" "--- Copying 'butane' binary to the current directory..."
printf "%-8s%-80s\n" "[INFO]" "    -- Source: '$BUTANE_PATH'"
cp "$BUTANE_PATH" ./butane || {
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to copy 'butane'. Check source path and permissions. Exiting..."
    exit 1
}
printf "%-8s%-80s\n" "[INFO]" "    -- Setting execute permissions for './butane'..."
chmod ug+x ./butane > /dev/null
if ! ./butane --version >/dev/null 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "       The copied 'butane' binary is not executable. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Required binaries (oc, openshift-install, butane) are now available ==="
ls -l oc openshift-install butane
echo ""