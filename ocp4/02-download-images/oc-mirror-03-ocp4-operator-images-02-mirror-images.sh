#!/bin/bash

### ---------------------------------------------------------------------------------
### OpenShift Operator Image Mirroring Execution
### ---------------------------------------------------------------------------------
### This script executes the 'oc-mirror' tool to mirror Operator (OLM) images
### using previously generated ImageSet configurations.

### Enable strict mode.
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

if [[ -z "${WORK_DIR:-}" || -z "${PULL_SECRET_FILE:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables are not set." >&2
    exit 1
fi

extract_ocp_versions
if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No valid OCP versions found." >&2
    exit 1
fi

if [[ ! -f "./oc-mirror" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    './oc-mirror' binary not found." >&2
    exit 1
fi

if [[ ! -d "$OC_MIRROR_CACHE_DIR" ]]; then
    mkdir -p "$OC_MIRROR_CACHE_DIR" && chmod 755 "$OC_MIRROR_CACHE_DIR"
fi

printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### ---------------------------------------------------------------------------------
### 3. Mirroring Function
### ---------------------------------------------------------------------------------
mirror_images() {
    local lc_config="$1"
    local lc_dest="$2"

    ### Prepare Command Array
    local CMD_ARGS=(
        "./oc-mirror"
        "--v2"
        "--authfile"      "$PULL_SECRET_FILE"
        "--log-level"     "$OC_MIRROR_LOG_LEVEL"
        "--cache-dir"     "$OC_MIRROR_CACHE_DIR"
        "--image-timeout" "$OC_MIRROR_IMAGE_TIMEOUT"
        "--retry-times"   "$OC_MIRROR_RETRY_TIMES"
        "--config"        "$lc_config"
        "file://$lc_dest"
    )

    local CMD_STRING="${CMD_ARGS[*]}"

    ### Log Parameters
    printf "%-8s%-80s\n" "[INFO]" "    --------------------------------------------------"
    printf "%-8s%-80s\n" "[INFO]" "    Parameters:"
    printf "%-8s%-80s\n" "[INFO]" "      - Config      : $lc_config"
    printf "%-8s%-80s\n" "[INFO]" "      - Destination : file://$lc_dest"
    printf "%-8s%-80s\n" "[INFO]" "      - cache-dir   : $OC_MIRROR_CACHE_DIR"
    printf "%-8s%-80s\n" "[INFO]" "    --------------------------------------------------"

    ### Execute the command
    printf "%-8s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-8s%-80s\n" "[INFO]" "        $CMD_STRING"
    "${CMD_ARGS[@]}" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Mirror command failed." >&2
        exit 1
    }
}

### ---------------------------------------------------------------------------------
### 4. Main Execution
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Operator Mirroring ==="

IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"
declare -a mirror_export_dirs=()

for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        printf "%-8s%-80s\n" "[INFO]" "--- Processing: $catalog (OCP $major_minor) ---"

        work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        config_file="$work_dir/imageset-config.yaml"
        mirror_export_dirs+=("$work_dir")

        if [[ ! -f "$config_file" ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Config file not found: $config_file" >&2
            exit 1
        fi

        ### Cleanup temp dir
        if [[ -d "$work_dir/working-dir" ]]; then
            printf "%-8s%-80s\n" "[INFO]" "    Cleaning up temp working-dir..."
            rm -rf "$work_dir/working-dir"
        fi

        mirror_images "$config_file" "$work_dir"
    done
done

### ---------------------------------------------------------------------------------
### 5. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Mirroring Completed ==="
printf "%-8s%-80s\n" "[INFO]" "    Locations:"

for dir in "${mirror_export_dirs[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "       ls -lh $dir"
    if [[ -d "$dir" ]]; then
        ls -lh "$dir" | grep -v "^total" || true
    else
         printf "%-8s%-80s\n" "[WARN]" "       Directory missing."
    fi
done
echo ""