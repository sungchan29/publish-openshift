#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Cluster Manifests
### ---------------------------------------------------------------------------------
### This script validates the environment and generates the final OpenShift cluster manifests using the 'openshift-install' binary.
### These manifests are required to create a bootable ISO image for agent-based installation.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Validate Tools
### ---------------------------------------------------------------------------------
### Source the main configuration file to load all necessary variables and functions.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Please check the file path." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Ensure the current directory is in PATH for direct binary execution.
if echo "$PATH" | grep -q "^$PWD"; then
    echo "INFO: Current directory is already in PATH. No action needed."
else
    export PATH="$PWD:$PATH"
    echo "INFO: Added current directory to PATH to find 'oc' and 'openshift-install'."
fi

### Check if the 'openshift-install' binary exists and is executable.
if [[ ! -x "./openshift-install" ]]; then
    echo "ERROR: The 'openshift-install' binary is not found or is not executable." >&2
    echo "INFO: To resolve this, please run 'abi-02-install-openshift-tools.sh' first." >&2
    exit 1
fi

### Validate that the configured OCP version matches the binary version.
echo "INFO: Validating configured OCP_VERSION ('$OCP_VERSION') against 'openshift-install' binary version..."
install_version=$(./openshift-install version | head -n 1 | awk '{print $2}' || echo "")
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    echo "ERROR: Version mismatch detected. Configured OCP_VERSION is '$OCP_VERSION', but the binary version is '$install_version'." >&2
    exit 1
fi
echo "INFO: Version match confirmed. Proceeding."

### ---------------------------------------------------------------------------------
### Validate Mirror Registry
### ---------------------------------------------------------------------------------
### Perform extensive checks on the mirror registry configuration.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    echo "INFO: Using the following release image override: $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"

    ### Validate that all required variables are set for a disconnected installation.
    for var in "MIRROR_REGISTRY" "LOCAL_REPOSITORY_NAME" "PULL_SECRET"; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: The required variable '$var' is empty. Please set it in the configuration script." >&2
            exit 1
        fi
    done
    
    ### Validate that the mirror registry certificate file exists and is not empty.
    if [[ ! -s "$MIRROR_REGISTRY_CRT_FILE" ]]; then
        echo "ERROR: The certificate file '$MIRROR_REGISTRY_CRT_FILE' is empty or does not exist." >&2
        exit 1
    fi
    if ! grep -q "^-----BEGIN CERTIFICATE-----" "$MIRROR_REGISTRY_CRT_FILE"; then
        echo "ERROR: The certificate file '$MIRROR_REGISTRY_CRT_FILE' does not appear to be a valid certificate." >&2
        exit 1
    fi
    
    ### Validate the pull secret file and its format.
    if command -v jq --version >/dev/null 2>&1; then
        if [[ ! -f "$PULL_SECRET" ]] || ! jq . "$PULL_SECRET" >/dev/null 2>&1; then
            echo "ERROR: The PULL_SECRET file '$PULL_SECRET' does not exist or is not a valid JSON file." >&2
            exit 1
        fi
    fi
    
    ### Test connectivity to the mirror registry.
    echo "INFO: Attempting to connect to the mirror registry at '$MIRROR_REGISTRY'..."
    if ! curl -s -k -m 10 "https://$MIRROR_REGISTRY/v2/" >/dev/null; then
        echo "WARNING: Failed to connect to the mirror registry. Proceeding without a connectivity check."
    else
        echo "INFO: Successfully connected to the mirror registry."
    fi

    ### Validate the release image with Podman.
    if command -v podman >/dev/null 2>&1; then
        echo "INFO: Validating the release image using Podman pull..."
        set +e
        output=$(podman pull --authfile "$PULL_SECRET" --tls-verify=false "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        pull_exit_code=$?
        set -e
        if [[ $pull_exit_code -ne 0 ]]; then
            echo "ERROR: Failed to pull the release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'." >&2
            echo "       Reason: $output" >&2
            exit 1
        fi
        echo "INFO: Release image pulled successfully."

        echo "INFO: Inspecting the release image to confirm integrity..."
        set +e
        output=$(podman inspect "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        inspect_exit_code=$?
        set -e
        if [[ $inspect_exit_code -ne 0 ]]; then
            echo "ERROR: Failed to inspect the release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'." >&2
            echo "       Reason: $output" >&2
            exit 1
        fi
        echo "INFO: Release image inspected successfully."
        podman rmi "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" || {
            echo "WARNING: Failed to remove the temporary release image from local storage."
        }
        echo "INFO: Temporary release image has been cleaned up."
    else
        echo "WARNING: 'podman' not found. Skipping release image validation."
    fi
fi

### ---------------------------------------------------------------------------------
### Copy Configuration Files
### ---------------------------------------------------------------------------------
### Copy the generated YAML files into the working directory for 'openshift-install'.
echo "--- Copying core configuration files to the cluster working directory..."
declare -a source_files=(
    "./$CLUSTER_NAME/orig/agent-config.yaml"
    "./$CLUSTER_NAME/orig/install-config.yaml"
)
for file in "${source_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: The required file '$file' is missing." >&2
        echo "INFO: Please ensure you have run previous scripts to generate all necessary files." >&2
        exit 1
    fi
    cp -f "$file" "./$CLUSTER_NAME/" || {
        echo "ERROR: Failed to copy '$file' to './$CLUSTER_NAME'." >&2
        exit 1
    }
    echo "INFO: Copied '$file' to './$CLUSTER_NAME'."
done

### Copy additional manifests from the user-defined directory.
echo "--- Copying additional user-defined manifests..."
if [[ -d "$ADDITIONAL_MANIFEST" ]]; then
    cp -Rf "$ADDITIONAL_MANIFEST" "./$CLUSTER_NAME/" || {
        echo "ERROR: Failed to copy additional manifests from '$ADDITIONAL_MANIFEST'." >&2
        exit 1
    }
    echo "INFO: All additional manifests copied successfully."
else
    echo "ERROR: The directory for additional manifests '$ADDITIONAL_MANIFEST' does not exist." >&2
    echo "INFO: Please create this directory or update the configuration variable." >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### Generate Cluster Manifests
### ---------------------------------------------------------------------------------
### Run 'openshift-install' to generate the final cluster manifests.
echo "--- Generating final cluster manifests in './$CLUSTER_NAME'..."
if ! ./openshift-install agent create cluster-manifests --dir "./$CLUSTER_NAME" --log-level info 2>&1; then
    echo "ERROR: Manifest generation failed. Review the logs above for specific errors." >&2
    exit 1
fi
echo "INFO: Cluster manifests generated successfully."

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### Display the directory structure for verification and provide a completion message.
echo "--- Listing the contents of the final working directory '$CLUSTER_NAME'..."
if command -v tree >/dev/null 2>&1; then
    tree "./$CLUSTER_NAME"
else
    echo "INFO: 'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "./$CLUSTER_NAME"
fi

echo "--- The manifest generation process is complete. You can now proceed to create the ISO."
