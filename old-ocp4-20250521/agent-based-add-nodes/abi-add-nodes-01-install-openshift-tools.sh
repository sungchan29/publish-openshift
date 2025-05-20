#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Validate required variables
validate_file "$OPENSHIFT_CLIENT_TAR_FILE"

### Clean up existing binaries
echo "[INFO] Starting cleanup of existing oc"
if [[ -f "./oc" ]]; then
    if lsof "./oc" >/dev/null 2>&1; then
        echo "[WARN] ./oc is in use. Skipping deletion."
    else
        echo "[INFO] Removing existing binary './oc'..."
        rm -f "./oc"
        echo "[INFO] Successfully removed './oc'."
    fi
fi
echo "[INFO] Completed cleanup of existing oc."

### Extract oc from tar file
echo "[INFO] Starting oc binary extraction..."
if ! tar -tf "$OPENSHIFT_CLIENT_TAR_FILE" oc >/dev/null 2>&1; then
    echo "[ERROR] OPENSHIFT_CLIENT_TAR_FILE does not contain oc binary. Exiting..."
    exit 1
fi

echo "[INFO] Extracting oc from '$OPENSHIFT_CLIENT_TAR_FILE'..."
tar xvf "$OPENSHIFT_CLIENT_TAR_FILE" -C "./" oc

echo "[INFO] Successfully extracted oc binary."

echo "[INFO] Setting permissions for oc..."
chmod ug+x ./oc
if ! ./oc version --client; then
    echo "[ERROR] Extracted oc is not executable. Exiting..."
    exit 1
fi

### Final completion message
echo "[INFO] All setup steps completed successfully."