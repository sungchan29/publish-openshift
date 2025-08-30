#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Configuration file '$config_file' does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Validate dependencies
if [[ ! -x "./oc" ]]; then
    echo "[ERROR] './oc' is not executable or does not exist. Exiting..."
    echo "[INFO] Ensure OpenShift CLI is installed and executable (chmod +x oc)."
    exit 1
fi
if [[ ! -x "./openshift-install" ]]; then
    echo "[ERROR] './openshift-install' is not executable or does not exist. Exiting..."
    echo "[INFO] To resolve this issue, run: sh abi-02-install-openshift-tools.sh"
    exit 1
fi
### Validate OCP_VERSION matches openshift-install version
echo "[INFO] Validating OCP_VERSION against openshift-install version..."
install_version=$(./openshift-install version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    echo "[ERROR] OCP_VERSION '$OCP_VERSION' does not match openshift-install version '$install_version'. Exiting..."
    exit 1
fi
echo "[INFO] OCP_VERSION '$OCP_VERSION' matches openshift-install version '$install_version'."

### Set release image override
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    echo "[INFO] $(env | grep OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE)"
fi

if echo "$PATH" | grep -q "^$PWD"; then
    echo "[INFO] Current directory is already in PATH."
else
    export PATH="$PWD:$PATH"
    echo "[INFO] Added current directory to PATH for 'oc'"
fi

### Generate agent ISO image
./openshift-install agent create image --dir "./$CLUSTER_NAME" --log-level info

### Rename ISO file
iso_file="./$CLUSTER_NAME/agent.x86_64.iso"
new_iso_file="./${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"
if [[ -f "$iso_file" ]]; then
    echo "[INFO] Renaming ISO file '$iso_file' to '$new_iso_file'..."
    if [[ -f "$new_iso_file" ]]; then
        if ! rm -f "$new_iso_file"; then
            echo "[ERROR] Failed to remove existing '$new_iso_file'. Check permissions. Exiting..."
            exit 1
        fi
    fi
    if ! mv "$iso_file" "$new_iso_file"; then
        echo "[ERROR] Failed to rename '$iso_file' to '$new_iso_file'. Check permissions or disk space. Exiting..."
        exit 1
    fi
    echo "[INFO] Successfully renamed ISO file to '$new_iso_file'."
else
    echo "[ERROR] ISO file '$iso_file' was not generated. Exiting..."
    exit 1
fi

### List directory structure (optional, for debugging)
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$PWD':"
    tree "$PWD"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "$PWD"
fi