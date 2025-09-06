#!/bin/bash

### ---------------------------------------------------------------------------------
### Create Bootable ISO Image
### ---------------------------------------------------------------------------------
### This script generates the bootable ISO for an agent-based installation, using
### the manifests and binaries prepared in previous steps.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Validate Tools
### ---------------------------------------------------------------------------------
### Source the configuration file to access all required variables.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Validate that the core binaries are executable.
echo "--- Validating core binaries..."
if [[ ! -x "./oc" ]]; then
    echo "ERROR: The 'oc' binary is not found or is not executable." >&2
    echo "INFO: Please ensure it is in the current directory and has execute permissions (chmod +x oc)." >&2
    exit 1
fi
if [[ ! -x "./openshift-install" ]]; then
    echo "ERROR: The 'openshift-install' binary is not found or is not executable." >&2
    echo "INFO: To resolve this, please run 'abi-02-install-openshift-tools.sh'." >&2
    exit 1
fi

### Validate that the configured OCP version matches the binary version.
echo "--- Validating configured OCP_VERSION ('$OCP_VERSION') against 'openshift-install' binary version..."
install_version=$(./openshift-install version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    echo "ERROR: Version mismatch detected. Configured OCP_VERSION is '$OCP_VERSION', but the binary version is '$install_version'." >&2
    exit 1
fi
echo "INFO: Version match confirmed. Proceeding."

### ---------------------------------------------------------------------------------
### Generate and Rename the ISO Image
### ---------------------------------------------------------------------------------
### Set the release image override if a mirror registry is configured.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    echo "INFO: Set OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE for disconnected installation."
fi

### Ensure the current directory is in PATH for direct binary execution.
if echo "$PATH" | grep -q "^$PWD"; then
    echo "INFO: Current directory is already in PATH. No action needed."
else
    export PATH="$PWD:$PATH"
    echo "INFO: Added current directory to PATH to find 'oc' and 'openshift-install'."
fi

### Generate the agent ISO image using the manifests in the cluster directory.
echo "--- Generating the agent ISO image..."
./openshift-install agent create image --dir "./$CLUSTER_NAME" --log-level info

### Rename the generated ISO file to include the cluster name and version.
echo "--- Renaming the ISO file for clarity..."
iso_file="./$CLUSTER_NAME/agent.x86_64.iso"
new_iso_file="./${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"
if [[ -f "$iso_file" ]]; then
    echo "INFO: Generated ISO file found at '$iso_file'."
    if [[ -f "$new_iso_file" ]]; then
        echo "WARNING: A file with the new name '$new_iso_file' already exists. Deleting it..."
        if ! rm -f "$new_iso_file"; then
            echo "ERROR: Failed to remove the existing file. Check permissions." >&2
            exit 1
        fi
    fi
    if ! mv "$iso_file" "$new_iso_file"; then
        echo "ERROR: Failed to rename '$iso_file' to '$new_iso_file'. Check permissions or disk space." >&2
        exit 1
    fi
    echo "INFO: Successfully renamed the ISO file to '$new_iso_file'."
else
    echo "ERROR: The ISO file '$iso_file' was not generated. Please check the logs above for errors." >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### List the contents of the working directory to show the generated files.
echo "--- The ISO image is ready. Final directory structure:"
if command -v tree >/dev/null 2>&1; then
    tree "."
else
    echo "INFO: 'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "."
fi
echo "--- ISO generation is complete. You can now use the ISO file for your installation."