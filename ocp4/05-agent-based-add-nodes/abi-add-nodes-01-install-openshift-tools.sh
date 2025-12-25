#!/bin/bash

### ---------------------------------------------------------------------------------
### Setup 'oc' Client for Adding Nodes
### ---------------------------------------------------------------------------------
### This script prepares the 'oc' (OpenShift Client) binary, which is required
### for interacting with the cluster to add new nodes.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
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
validate_file "$OPENSHIFT_CLIENT_TAR_FILE"

### ---------------------------------------------------------------------------------
### Prepare 'oc' Binary
### ---------------------------------------------------------------------------------
### Clean up any previously extracted 'oc' binary to ensure a fresh version is used.
printf "%-8s%-80s\n" "[INFO]" "=== Cleaning up previous 'oc' binary ==="
if [[ -f "./oc" ]]; then
    if lsof "./oc" >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[WARN]" "    The './oc' binary is currently in use. Skipping removal."
    else
        printf "%-8s%-80s\n" "[INFO]" "    > Removing existing './oc' binary..."
        rm -f "./oc"
    fi
fi

### Extract the 'oc' binary from the client tools tarball.
printf "%-8s%-80s\n" "[INFO]" "=== Extracting 'oc' binary ==="
if ! tar -tf "$OPENSHIFT_CLIENT_TAR_FILE" oc >/dev/null 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "    The tar file '$OPENSHIFT_CLIENT_TAR_FILE' does not contain an 'oc' binary. Exiting..."
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "    > Extracting 'oc' from '$OPENSHIFT_CLIENT_TAR_FILE'..."
### Using 'xf' instead of 'xvf' and redirecting output to keep the log clean.
tar xf "$OPENSHIFT_CLIENT_TAR_FILE" -C "./" oc

printf "%-8s%-80s\n" "[INFO]" "    > Setting execute permissions for './oc'..."
chmod ug+x ./oc
if ! ./oc version --client >/dev/null 2>&1; then
    printf "%-8s%-80s\n" "[ERROR]" "    The extracted './oc' binary is not executable. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Finalization
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Setup of OpenShift client tools completed successfully ==="
ls -l ./oc
echo ""