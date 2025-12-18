#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Container Info
CLAIR_CONTAINER_NAME="clair"
CLAIR_CONFIG_PATH="/config/config.yaml"  # Path INSIDE the container

### 2. Import File Info
### Place the transferred file in /tmp or current directory
IMPORT_FILE_PATH="./clair-vulnerabilities.tar.gz"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

if [[ $EUID -ne 0 ]]; then echo "[ERROR] Run as root."; exit 1; fi

echo "################################################################################"
echo " [STEP 2] Clair Vulnerability Data Importer"
echo "################################################################################"
echo " Target Container : $CLAIR_CONTAINER_NAME"
echo " Import File      : $IMPORT_FILE_PATH"
echo "################################################################################"
echo ""

### 1. Pre-flight Checks
if [[ ! -f "$IMPORT_FILE_PATH" ]]; then
    echo "[ERROR] Import file not found at: $IMPORT_FILE_PATH"
    echo "Please transfer the 'clair-vulnerabilities.tar.gz' file first."
    exit 1
fi

if ! podman ps --format "{{.Names}}" | grep -q "^${CLAIR_CONTAINER_NAME}$"; then
    echo "[ERROR] Clair container '$CLAIR_CONTAINER_NAME' is NOT running."
    echo "Please start Clair first."
    exit 1
fi

### 2. Copy File to Container
echo " > Copying file into container..."
podman cp "$IMPORT_FILE_PATH" "${CLAIR_CONTAINER_NAME}:/tmp/clair-update.tar.gz"

if [[ $? -ne 0 ]]; then
    echo "[ERROR] Failed to copy file to container."
    exit 1
fi

### 3. Execute Import Command
echo " > Executing import-updaters (This may take a few minutes)..."

podman exec -it "$CLAIR_CONTAINER_NAME" \
    clairctl --config "$CLAIR_CONFIG_PATH" \
    import-updaters "/tmp/clair-update.tar.gz"

IMPORT_EXIT_CODE=$?

### 4. Cleanup & Result
echo " > Cleaning up temporary file inside container..."
podman exec -it "$CLAIR_CONTAINER_NAME" rm -f "/tmp/clair-update.tar.gz"

if [[ $IMPORT_EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "=================================================================="
    echo " [SUCCESS] Vulnerability Database Updated!"
    echo "=================================================================="
    echo " Clair is now processing the new data."
    echo " Existing 'Queued' scans should start processing shortly."
    echo ""
    echo " To check logs:"
    echo "   podman logs -f $CLAIR_CONTAINER_NAME"
else
    echo ""
    echo "[ERROR] Import command failed with exit code $IMPORT_EXIT_CODE."
    echo "Check the logs above for details."
    exit 1
fi