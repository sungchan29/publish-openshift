#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Cluster Manifests
### ---------------------------------------------------------------------------------
### This script validates the environment and then generates the final OpenShift cluster
### manifests using the 'openshift-install' binary. These manifests are required to
### create the bootable ISO for an agent-based installation.

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
printf "%-8s%-80s\n" "[INFO]" "=== Verifying Prerequisites and 'openshift-install' Binary ==="
printf "%-8s%-80s\n" "[INFO]" "--- Ensuring the current directory is in the system's PATH..."
### Ensure the current directory is in the system's PATH for direct binary execution.
if  echo "$PATH" | grep -q "^$PWD"; then
    echo "$PATH"
else
    printf "%-8s%-80s\n" "[INFO]" "--- Added current directory to PATH to ensure binaries are found."
    printf "%-8s%-80s\n" "[INFO]" "    Executing:"
    printf "%-8s%-80s\n" "[INFO]" "        export PATH=\"\$PWD:\$PATH\""
    export PATH="$PWD:$PATH"
    echo "$PATH"
fi

printf "%-8s%-80s\n" "[INFO]" "--- Check if the 'openshift-install' binary exists and is executable..."
if [[ ! -x "./openshift-install" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The './openshift-install' binary is not found or is not executable. Exiting..."
    exit 1
fi
printf "%-8s%-80s\n" "[INFO]" "--- Validating configured OCP_VERSION ('$OCP_VERSION') against the 'openshift-install' binary..."
install_version=$(./openshift-install version | head -n 1 | awk '{print $2}' || echo "")
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Version mismatch: Configured version is '$OCP_VERSION', but binary version is '$install_version'. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Generating Cluster Manifests
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Generating Cluster Manifests ==="
### Perform extensive checks on the mirror registry configuration for a disconnected install.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    target_image="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    printf "%-8s%-80s\n" "[INFO]" "--- Set OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE for disconnected installation."
    printf "%-8s%-80s\n" "[INFO]" "    Executing:"
    printf "%-8s%-80s\n" "[INFO]" "        export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=\"$target_image\""
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$target_image"

    ### Validate that all required variables are set.
    for var in "MIRROR_REGISTRY" "LOCAL_REPOSITORY_NAME" "PULL_SECRET"; do
        if [[ -z "${!var}" ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Required disconnected installation variable '$var' is not set. Exiting..."
            exit 1
        fi
    done

    ### Test connectivity to the mirror registry.
    printf "%-8s%-80s\n" "[INFO]" "--- Testing connectivity to the mirror registry at '$MIRROR_REGISTRY'..."
    if ! curl -s -k -m 10 "https://$MIRROR_REGISTRY/v2/" >/dev/null; then
        printf "%-8s%-80s\n" "[ERROR]" "    Could not connect to the mirror registry. Proceeding without connectivity check."
        exit 1
    fi

    ### Validate the release image with Podman if available.
    if command -v podman >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[INFO]" "--- Validating release image with 'podman pull'..."
        set +e
        output=$(podman pull --authfile "$PULL_SECRET" --tls-verify=false "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        pull_exit_code=$?
        set -e
        if [[ $pull_exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to pull the release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'. Exiting..."
            printf "%-8s%-80s\n" "[ERROR]" "    - Reason: $output" >&2
            exit 1
        fi

        printf "%-8s%-80s\n" "[INFO]" "--- Inspecting the release image to confirm integrity..."
        set +e
        output=$(podman inspect "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        inspect_exit_code=$?
        set -e
        if [[ $inspect_exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to inspect the release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'. Exiting..."
            printf "%-8s%-80s\n" "[ERROR]" "    - Reason: $output" >&2
            exit 1
        fi
        printf "%-8s%-80s\n" "[INFO]" "--- Temporary release image has been cleaned up."
        podman rmi "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" &>/dev/null || printf "%-13s%-80s\n" "[WARN]" "    Failed to remove the temporary release image from local storage."
    else
        printf "%-8s%-80s\n" "[WARN]" "    Skipping release image validation. Reason: 'podman' command not found."
    fi
fi

### ---------------------------------------------------------------------------------
### Copy Configuration Files
### ---------------------------------------------------------------------------------
### Copy the generated YAML files into the working directory for 'openshift-install'.
printf "%-8s%-80s\n" "[INFO]" "--- Copying Base Configuration Files to Working Directory..."
declare -a source_files=(
    "./$CLUSTER_NAME/orig/agent-config.yaml"
    "./$CLUSTER_NAME/orig/install-config.yaml"
)
for file in "${source_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "    Required configuration file '$file' is missing. Exiting..."
        exit 1
    fi
    cp -f "$file" "./$CLUSTER_NAME/" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to copy '$file' to './$CLUSTER_NAME'. Exiting..."
        exit 1
    }
done

### Copy additional manifests from the user-defined directory.
printf "%-8s%-80s\n" "[INFO]" "--- Copying additional user-defined manifests ..."
if [[ -d "$ADDITIONAL_MANIFEST" ]]; then
    cp -Rf "$ADDITIONAL_MANIFEST" "./$CLUSTER_NAME/" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to copy additional manifests from '$ADDITIONAL_MANIFEST'. Exiting..."
        exit 1
    }
fi

### ---------------------------------------------------------------------------------
### Generate Cluster Manifests
### ---------------------------------------------------------------------------------
### Run 'openshift-install' to generate the final cluster manifests from the configuration.
install_cmd=(
    "./openshift-install"
    "agent"
    "create"
    "cluster-manifests"
    "--dir" "./$CLUSTER_NAME"
    "--log-level" "info"
)
install_cmd_str="${install_cmd[*]}"

printf "%-8s%-80s\n" "[INFO]" "--- Generating final cluster manifests in './$CLUSTER_NAME' ..."
printf "%-8s%-80s\n" "[INFO]" "    Executing:"
printf "%-8s%-80s\n" "[INFO]" "        $install_cmd_str"
if ! "${install_cmd[@]}" 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "    'openshift-install' failed to generate manifests. Review logs for details. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### Display the directory structure for user verification and provide a completion message.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Verifying generated files ==="
printf "%-8s%-80s\n" "[INFO]" "    Displaying directory structure for '$CLUSTER_NAME':"
if command -v tree >/dev/null 2>&1; then
    tree "./$CLUSTER_NAME"
else
    printf "%-8s%-80s\n" "[INFO]" "    'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "./$CLUSTER_NAME"
fi
echo ""
printf "%-8s%-80s\n" "[INFO]" "--- Manifest generation complete. You can now create the ISO ---"
echo ""