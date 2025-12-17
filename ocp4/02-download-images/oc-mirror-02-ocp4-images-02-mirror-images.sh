#!/bin/bash

### ---------------------------------------------------------------------------------
### Mirror OpenShift Release Images
### ---------------------------------------------------------------------------------
### This script mirrors OpenShift Container Platform (OCP) release images using
### the 'oc-mirror' tool and previously generated ImageSet configurations.

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
if [[ -z "${WORK_DIR:-}" || -z "${PULL_SECRET_FILE:-}" || -z "${log_dir:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set." >&2
    exit 1
fi

### Extract OCP versions
printf "%-8s%-80s\n" "[INFO]" "    Verifying OpenShift Versions..."
extract_ocp_versions

if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No valid OCP versions found. Check 'OCP_VERSIONS' in config." >&2
    exit 1
fi

### Check for the 'oc-mirror' binary
if [[ ! -f "$PWD/oc-mirror" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The './oc-mirror' binary was not found at '$PWD/oc-mirror'." >&2
    exit 1
fi

### Create cache directory if needed
if [[ ! -d "$OC_MIRROR_CACHE_DIR" ]]; then
    mkdir -p "$OC_MIRROR_CACHE_DIR" && chmod 755 "$OC_MIRROR_CACHE_DIR"
fi

printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### ---------------------------------------------------------------------------------
### 3. Mirroring Function
### ---------------------------------------------------------------------------------
mirror_images() {
    local lc_imageset_config_file="$1"
    local lc_oc_mirror_work_dir="$2"

    ### 1. Define the command and arguments as an array (Safe for spaces)
    local CMD_ARGS=(
        "$PWD/oc-mirror"
        "--v2"
        "--authfile"      "$PULL_SECRET_FILE"
        "--log-level"     "$OC_MIRROR_LOG_LEVEL"
        "--cache-dir"     "$OC_MIRROR_CACHE_DIR"
        "--image-timeout" "$OC_MIRROR_IMAGE_TIMEOUT"
        "--retry-times"   "$OC_MIRROR_RETRY_TIMES"
        "--config"        "$lc_imageset_config_file"
        "file://$lc_oc_mirror_work_dir"
    )

    ### 2. Construct a string for logging purposes
    local CMD_STRING="${CMD_ARGS[*]}"

    ### 3. Log the parameters and the full command
    printf "%-8s%-80s\n" "[INFO]" "    --------------------------------------------------"
    printf "%-8s%-80s\n" "[INFO]" "    Parameters:"
    printf "%-8s%-80s\n" "[INFO]" "      - Config File : $(basename "$lc_imageset_config_file")"
    printf "%-8s%-80s\n" "[INFO]" "      - Destination : file://$lc_oc_mirror_work_dir"
    printf "%-8s%-80s\n" "[INFO]" "      - Cache Dir   : $OC_MIRROR_CACHE_DIR"
    printf "%-8s%-80s\n" "[INFO]" "    --------------------------------------------------"
    printf "%-8s%-80s\n" "[INFO]" "    Command to be executed:"
    echo "$CMD_STRING"
    printf "%-8s%-80s\n" "[INFO]" "    --------------------------------------------------"
    printf "%-8s%-80s\n" "[INFO]" "    Executing 'oc-mirror'..."

    ### 4. Execute the command
    "${CMD_ARGS[@]}" || {
        printf "%-8s%-80s\n" "[ERROR]" "    'oc-mirror' command failed. Check output above." >&2
        exit 1
    }
}

### ---------------------------------------------------------------------------------
### 4. Main Execution
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Mirroring Process ==="

declare -a mirror_export_dirs=()

### Loop through each OCP version
for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "--- Processing OCP Version: $major_minor_patch ---"

    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$major_minor_patch"
    mirror_export_dirs+=("$oc_mirror_work_dir")
    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

    ### Check Config File
    if [[ ! -f "$imageset_config_file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "    Config file not found: $imageset_config_file" >&2
        exit 1
    fi

    ### Clean up previous working-dir (Important for oc-mirror idempotency/issues)
    if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    Cleaning up existing 'working-dir'..."
        rm -Rf "$oc_mirror_work_dir/working-dir"
    fi

    ### Run Mirroring
    mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
done

### ---------------------------------------------------------------------------------
### 5. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Mirroring Process Completed ==="
printf "%-8s%-80s\n" "[INFO]" "    Mirrored image sets are located in:"

for export_dir in "${mirror_export_dirs[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    -> $export_dir"
    ### List files with indentation for better readability
    if [[ -d "$export_dir" ]]; then
        ls -lh "$export_dir" | grep -v "^total" || true
    else
        printf "%-8s%-80s\n" "[WARN]" "       Directory not found or empty."
    fi
done
echo ""