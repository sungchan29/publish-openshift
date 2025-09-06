#!/bin/bash

### ---------------------------------------------------------------------------------
### Setup Script for Agent-Based Installation
### ---------------------------------------------------------------------------------
### This script prepares the necessary binaries and configuration files for an
### OpenShift Agent-Based Installation (ABI), which is part of the disconnected
### cluster installation process.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration
### ---------------------------------------------------------------------------------
### Source the main configuration file to load all necessary variables.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"

### Check if the configuration file exists and source it.
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' could not be found. Please ensure it exists and try again."
    exit 1
fi

if ! source "$config_file"; then
    echo "ERROR: Failed to load the configuration file '$config_file'. Please check its syntax and permissions."
    exit 1
fi

### Validate that all required variables are set before proceeding.
validate_non_empty "LOCAL_REPOSITORY_NAME" "$LOCAL_REPOSITORY_NAME"
validate_file "$PULL_SECRET"
validate_file "$OPENSHIFT_CLIENT_TAR_FILE"
validate_file "$BUTANE_FILE"

### ---------------------------------------------------------------------------------
### Binary Cleanup
### ---------------------------------------------------------------------------------
### Clean up any previously extracted binaries to ensure a fresh start.
echo "Starting cleanup of existing installation binaries..."
for binary in oc openshift-install butane; do
    if [[ -f "./$binary" ]]; then
        ### Check if the binary is currently in use before attempting to delete it.
        if lsof "./$binary" >/dev/null 2>&1; then
            echo "WARNING: The '$binary' binary is currently in use. Skipping its removal."
        else
            echo "   - Removing old binary: '$binary'..."
            rm -f "./$binary"
            echo "   - '$binary' successfully removed."
        fi
    fi
done
echo "Cleanup of binaries completed."

### ---------------------------------------------------------------------------------
### Binary Extraction and Installation
### ---------------------------------------------------------------------------------

### 1. Extract 'oc' Binary
### The 'oc' binary is the OpenShift client and a prerequisite for other steps.
echo "Extracting **oc** client from '$OPENSHIFT_CLIENT_TAR_FILE'..."
tar xvf "$OPENSHIFT_CLIENT_TAR_FILE" -C "./" oc

echo "**oc** client successfully extracted."
echo "   - Setting execute permissions for **oc**..."
chmod ug+x ./oc

### 2. Create 'ImageDigestMirrorSet' Manifest
### This manifest (YAML) tells the 'oc' command where to find the mirrored release images
### and other content in the disconnected environment.
echo "Creating the **idms-oc-mirror.yaml** manifest file..."
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
    echo "ERROR: Failed to create **idms-oc-mirror.yaml**. Check file permissions or disk space."
    exit 1
fi
echo "**idms-oc-mirror.yaml** created successfully."

### 3. Extract 'openshift-install' Binary
### The 'openshift-install' binary is extracted directly from the mirrored release image
### using the 'oc' client and the newly created IDMS file.
echo "Starting **openshift-install** extraction..."
if [[ -f ./oc ]] && [[ -f ./idms-oc-mirror.yaml ]]; then
    echo "   - Pulling **openshift-install** from release image '$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64'..."
    ./oc adm release extract -a "$PULL_SECRET" --insecure=true --idms-file='./idms-oc-mirror.yaml' --command=openshift-install "$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"

    if [[ ! -f ./openshift-install ]]; then
        echo "ERROR: **openshift-install** binary not found after extraction. Please verify your mirrored image and pull secret."
        exit 1
    fi
    echo "**openshift-install** successfully extracted."
    echo "   - Setting execute permissions for **openshift-install**..."
    chmod ug+x ./openshift-install
    if ! ./openshift-install version >/dev/null 2>&1; then
        echo "ERROR: The extracted **openshift-install** binary is not executable. Exiting..."
        exit 1
    fi
    echo "**openshift-install** binary is now ready to use."
else
    echo "ERROR: Prerequisites (**oc** client or **idms-oc-mirror.yaml**) are missing. Exiting..."
    exit 1
fi

### 4. Copy 'butane' Binary
### The 'butane' binary is used to process Ignition configuration files for the cluster nodes.
echo "Copying **butane** binary..."
echo "   - Source: '$BUTANE_FILE'"
echo "   - Destination: './butane'"
cp "$BUTANE_FILE" ./butane || {
    echo "ERROR: Failed to copy **butane**. Check source file path and permissions."
    exit 1
}
echo "**butane** successfully copied."
echo "   - Setting execute permissions for **butane**..."
chmod ug+x ./butane
if ! ./butane --version >/dev/null 2>&1; then
    echo "ERROR: The copied **butane** binary is not executable. Exiting..."
    exit 1
fi
echo "**butane** binary is now ready to use."

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
echo "All setup steps are complete! The necessary binaries are now available in the current directory."