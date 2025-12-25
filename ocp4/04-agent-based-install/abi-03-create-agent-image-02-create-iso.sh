#!/bin/bash

### ---------------------------------------------------------------------------------
### Create Bootable ISO Image
### ---------------------------------------------------------------------------------
### This script generates the final, bootable agent-based installation (ABI) ISO
### using the manifests and binaries prepared in previous steps.

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

printf "%-8s%-80s\n" "[INFO]" "--- Validating required binaries ('oc', 'openshift-install')..."
if [[ ! -x "./oc" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The 'oc' binary is not found or is not executable. Exiting..."
    exit 1
fi
if [[ ! -x "./openshift-install" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The 'openshift-install' binary is not found or is not executable. Exiting..."
    exit 1
fi

### Validate that the configured OCP version matches the binary's version.
printf "%-8s%-80s\n" "[INFO]" "--- Validating OCP version consistency ..."
install_version=$(./openshift-install version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Version mismatch: Configured version is '$OCP_VERSION', but binary version is '$install_version'. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Generate and Rename the ISO Image
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Generating the Agent ISO Image ==="
### Set the release image override if a mirror registry is configured for disconnected installation.
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    target_image="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    printf "%-8s%-80s\n" "[INFO]" "--- Set OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE for disconnected installation."
    printf "%-8s%-80s\n" "[INFO]" "    Executing:"
    printf "%-8s%-80s\n" "[INFO]" "        export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=\"$target_image\""
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$target_image"
fi

### Generate the agent ISO image using the manifests in the cluster directory.
iso_cmd=(
    "./openshift-install"
    "agent"
    "create"
    "image"
    "--dir" "./$CLUSTER_NAME"
    "--log-level" "info"
)
iso_cmd_str="${iso_cmd[*]}"

printf "%-8s%-80s\n" "[INFO]" "--- Generating Agent ISO image ..."
printf "%-8s%-80s\n" "[INFO]" "    Executing:"
printf "%-8s%-80s\n" "[INFO]" "        $iso_cmd_str"
if ! "${iso_cmd[@]}"; then
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to generate Agent ISO image. Review logs for details. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Rename ISO (In-Place)
### ---------------------------------------------------------------------------------
# Default generated filename by openshift-install inside the cluster directory
default_iso_path="./$CLUSTER_NAME/agent.x86_64.iso"
# Desired filename within the same directory
final_iso_name="${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"
final_iso_path="./$CLUSTER_NAME/$final_iso_name"

printf "%-8s%-80s\n" "[INFO]" "--- Renaming the generated ISO file (In-Place)..."

if [[ -f "$default_iso_path" ]]; then
    # Check if the target file already exists and remove it to avoid errors or confusion
    if [[ -f "$final_iso_path" ]]; then
        printf "%-8s%-80s\n" "[WARN]" "    Existing file '$final_iso_name' found. Overwriting..."
        rm -f "$final_iso_path"
    fi

    # Rename the file
    mv "$default_iso_path" "$final_iso_path"
    printf "%-8s%-80s\n" "[INFO]" "    Renamed: 'agent.x86_64.iso' -> '$final_iso_name'"
    printf "%-8s%-80s\n" "[INFO]" "    Location: $final_iso_path"
else
    printf "%-8s%-80s\n" "[ERROR]" "    Expected ISO file '$default_iso_path' was not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
### List the contents of the working directory to show the generated files.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Verifying generated files ==="
printf "%-8s%-80s\n" "[INFO]" "--- Displaying directory structure for '$CLUSTER_NAME':"
if command -v tree >/dev/null 2>&1; then
    tree "./$CLUSTER_NAME"
else
    printf "%-8s%-80s\n" "[INFO]" "  'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "./$CLUSTER_NAME"
fi
echo ""
printf "%-8s%-80s\n"     "[INFO]" "--- The bootable ISO is ready for installation ---"
ls -lh "$final_iso_path" || {
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to list the final ISO file '$final_iso_path'. Exiting..."
}
echo ""