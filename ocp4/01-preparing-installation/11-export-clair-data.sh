#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Image Info (Must match the version used in internal network)
CLAIR_IMAGE="registry.redhat.io/quay/clair-rhel8:v3.15.2"

### 2. Output Settings
OUTPUT_DIR="$(pwd)"
OUTPUT_FILENAME="clair-vulnerabilities.tar.gz"
FULL_OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_FILENAME}"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

echo "################################################################################"
echo " [STEP 1] Clair Vulnerability Data Exporter"
echo "################################################################################"
echo " This script will download the latest CVE data from the internet."
echo " Target Image : $CLAIR_IMAGE"
echo " Output File  : $FULL_OUTPUT_PATH"
echo "################################################################################"
echo ""

### 1. Check Podman/Docker
CONTAINER_CMD="podman"
if ! command -v podman &> /dev/null; then
    if command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
    else
        echo "[ERROR] Neither podman nor docker found."
        exit 1
    fi
fi
echo " > Using container engine: $CONTAINER_CMD"

### 2. Run Export
echo ""
echo "Starting Export Process..."
echo "This may take 5-20 minutes depending on network speed."

$CONTAINER_CMD run --rm \
    --volume "${OUTPUT_DIR}:/data:Z" \
    "$CLAIR_IMAGE" \
    clairctl export-updaters "/data/${OUTPUT_FILENAME}"

### 3. Verify Result
if [[ -f "$FULL_OUTPUT_PATH" ]]; then
    FILE_SIZE=$(du -h "$FULL_OUTPUT_PATH" | cut -f1)
    echo ""
    echo "=================================================================="
    echo " [SUCCESS] Export Completed!"
    echo "=================================================================="
    echo " File Created : $FULL_OUTPUT_PATH"
    echo " Size         : $FILE_SIZE"
    echo "=================================================================="
    echo " [NEXT STEP]"
    echo " 1. Transfer this file to your disconnected Quay/Clair server."
    echo " 2. Run the 'import' script on that server."
else
    echo ""
    echo "[ERROR] Export failed. File not created."
    exit 1
fi