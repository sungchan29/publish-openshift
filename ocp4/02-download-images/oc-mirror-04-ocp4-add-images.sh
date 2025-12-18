#!/bin/bash

### ---------------------------------------------------------------------------------
### Mirror Additional and Tool Images
### ---------------------------------------------------------------------------------
### This script pulls or builds supplementary images (e.g., for logging, support,
### and upgrade graphs) and saves them as local tar archives.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### 1. Load Configuration
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Loading Configuration ==="

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/oc-mirror-00-config-setup.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"
printf "%-8s%-80s\n" "[INFO]" "    Configuration loaded from: $(basename "$CONFIG_FILE")"

### ---------------------------------------------------------------------------------
### 2. Environment Validation
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Validating Environment ==="

### Validate critical variables
if [[ -z "${WORK_DIR:-}" || -z "${PULL_SECRET_FILE:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, PULL_SECRET_FILE) are not set." >&2
    exit 1
fi

### Validate specific image variables
if [[ -z "${EVENTROUTER_IMAGE:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    'EVENTROUTER_IMAGE' is not set." >&2
    exit 1
fi
if [[ -z "${SUPPORT_TOOL_IMAGE:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    'SUPPORT_TOOL_IMAGE' is not set." >&2
    exit 1
fi

### Set default directory paths if not already defined (Fallback)
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

printf "%-8s%-80s\n" "[INFO]" "    - Output Directory : $OCP_TOOL_IMAGE_DIR"
printf "%-8s%-80s\n" "[INFO]" "    - Pull Secret File : $PULL_SECRET_FILE"
printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### ---------------------------------------------------------------------------------
### 3. Preparation
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Preparing Directories ==="

if [[ -d "$OCP_TOOL_IMAGE_DIR" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    Cleaning up previous tar files in '$OCP_TOOL_IMAGE_DIR'..."
    rm -f "$OCP_TOOL_IMAGE_DIR"/*.tar
else
    printf "%-8s%-80s\n" "[INFO]" "    Creating additional images directory..."
    mkdir -p "$OCP_TOOL_IMAGE_DIR"
fi

### ---------------------------------------------------------------------------------
### 4. Build Graph Data Image
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Processing: OpenShift Graph Data Image ==="

### Generate the Dockerfile
create_dockerfile

if [[ -f ./Dockerfile ]]; then
    GRAPH_IMAGE="localhost/openshift/graph-data:latest"
    GRAPH_TAR="$OCP_TOOL_IMAGE_DIR/localhost_graph-data.tar"

    printf "%-8s%-80s\n" "[INFO]" "--- Building Image ---"

    ### 1. Build Command
    CMD_BUILD=(
        "podman" "build"
        "-t" "$GRAPH_IMAGE"
        "-f" "./Dockerfile"
        "--authfile" "$PULL_SECRET_FILE"
        "."
    )
    printf "%-8s%-80s\n" "[INFO]" "    Command: ${CMD_BUILD[*]}"
    "${CMD_BUILD[@]}" >/dev/null

    printf "%-8s%-80s\n" "[INFO]" "--- Saving Image to Tar ---"

    ### 2. Save Command
    CMD_SAVE=(
        "podman" "save"
        "-o" "$GRAPH_TAR"
        "$GRAPH_IMAGE"
    )
    printf "%-8s%-80s\n" "[INFO]" "    Command: ${CMD_SAVE[*]}"
    "${CMD_SAVE[@]}"

    ### Cleanup
    rm -f ./Dockerfile
    printf "%-8s%-80s\n" "[INFO]" "    Graph data image saved: $(basename "$GRAPH_TAR")"

else
    printf "%-8s%-80s\n" "[ERROR]" "    Dockerfile generation failed. Skipping graph-data." >&2
fi

### ---------------------------------------------------------------------------------
### 5. Pull and Save Additional Images
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Processing: Additional Tools Images ==="

for image in ${EVENTROUTER_IMAGE} ${SUPPORT_TOOL_IMAGE}; do
    printf "%-8s%-80s\n" "[INFO]" "--- Processing Image: $image ---"

    ### Determine Local Tag Name
    # Removes the registry part (everything before the first /)
    # e.g. registry.redhat.io/rhel9/support-tools -> rhel9/support-tools
    image_path="${image#*/}"
    local_tag="localhost/$image_path"

    # Determine Tar Filename
    # e.g. support-tools:latest -> support-tools
    # Uses bash string manipulation instead of complex awk
    image_name_tag="${image##*/}"
    image_name_only="${image_name_tag%%:*}"
    target_tar="$OCP_TOOL_IMAGE_DIR/localhost_${image_name_only}.tar"

    ### 1. Pull Image
    CMD_PULL=(
        "podman" "pull"
        "$image"
        "--authfile" "$PULL_SECRET_FILE"
    )
    printf "%-8s%-80s\n" "[INFO]" "    1. Pulling..."
    printf "%-8s%-80s\n" "[INFO]" "       Command:"
    echo "${CMD_PULL[*]}"
    "${CMD_PULL[@]}" >/dev/null

    ### 2. Tag Image
    CMD_TAG=(
        "podman" "tag"
        "$image"
        "$local_tag"
    )
    printf "%-8s%-80s\n" "[INFO]" "    2. Tagging as '$local_tag'..."
    "${CMD_TAG[@]}"

    ### 3. Save Image
    CMD_SAVE=(
        "podman" "save"
        "-o" "$target_tar"
        "$local_tag"
    )
    printf "%-8s%-80s\n" "[INFO]" "    3. Saving to '$(basename "$target_tar")'..."
    printf "%-8s%-80s\n" "[INFO]" "       Command:"
    echo "${CMD_SAVE[*]}"
    "${CMD_SAVE[@]}"

    ### 4. Cleanup Local Tag
    CMD_RMI=(
        "podman" "rmi"
        "$local_tag"
    )
    printf "%-8s%-80s\n" "[INFO]" "    4. Cleaning up local tag..."
    "${CMD_RMI[@]}" >/dev/null

    ### 5. Verify (Optional Load check)
    printf "%-8s%-80s\n" "[INFO]" "    5. Verifying tar archive..."
    if podman load -i "$target_tar" >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[INFO]" "       Verification successful."
    else
        printf "%-8s%-80s\n" "[WARN]" "       Verification failed (podman load check)."
    fi
done

### ---------------------------------------------------------------------------------
### 6. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Mirroring Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Output Directory: $OCP_TOOL_IMAGE_DIR"
printf "%-8s%-80s\n" "[INFO]" "    Generated Files:"

if [[ -d "$OCP_TOOL_IMAGE_DIR" ]]; then
    ls -lh "$OCP_TOOL_IMAGE_DIR" | grep -v "^total" || true
else
    printf "%-8s%-80s\n" "[WARN]" "    Directory not found."
fi
echo ""