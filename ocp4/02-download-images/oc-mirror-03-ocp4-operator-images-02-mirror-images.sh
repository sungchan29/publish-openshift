#!/bin/bash

### ---------------------------------------------------------------------------------
### OpenShift Operator Image Mirroring Execution
### ---------------------------------------------------------------------------------
### This script executes the 'oc-mirror' tool to mirror Operator (OLM) images to a local directory, using previously generated ImageSet configurations.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
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
if [[ -z "$WORK_DIR" || -z "$PULL_SECRET_FILE" || -z "$log_dir" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set. Exiting..."
    exit 1
fi

### Extract OCP versions from the configuration.
extract_ocp_versions

### Validate that OCP versions were found.
if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    OCP_VERSION_ARRAY is empty. Check 'OCP_VERSIONS' in your config. Exiting..."
    exit 1
fi

### Initialize an array to store the paths of mirrored image sets for the final summary.
declare -a mirror_export_dirs=()

### Check for the 'oc-mirror' binary in the current working directory.
if [[ ! -f "$PWD/oc-mirror" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The './oc-mirror' binary was not found at '$PWD/oc-mirror'. Exiting..."
    exit 1
fi

### Create the oc-mirror cache directory if it does not exist.
if [[ ! -d "$OC_MIRROR_CACHE_DIR" ]]; then
    mkdir -p "$OC_MIRROR_CACHE_DIR" && chmod 755 "$OC_MIRROR_CACHE_DIR"
fi

### ---------------------------------------------------------------------------------
### Mirroring Execution Function
### ---------------------------------------------------------------------------------
### Defines the core function to execute the 'oc-mirror' command.
### This function takes an ImageSet configuration file and a destination directory
### as arguments, then invokes 'oc-mirror' with parameters from the configuration file.
mirror_images() {
    local lc_imageset_config_file="$1"
    local lc_oc_mirror_work_dir="$2"

    ### Log the parameters being used for mirroring.
    printf "%-8s%-80s\n" "[INFO]" "--- Using the following parameters:"
    printf "%-8s%-80s\n" "[INFO]" "    - authfile       : $PULL_SECRET_FILE"
    printf "%-8s%-80s\n" "[INFO]" "    - log-level      : $OC_MIRROR_LOG_LEVEL"
    printf "%-8s%-80s\n" "[INFO]" "    - cache-dir      : $OC_MIRROR_CACHE_DIR"
    printf "%-8s%-80s\n" "[INFO]" "    - image-timeout  : $OC_MIRROR_IMAGE_TIMEOUT"
    printf "%-8s%-80s\n" "[INFO]" "    - retry-times    : $OC_MIRROR_RETRY_TIMES"
    printf "%-8s%-80s\n" "[INFO]" "    - config         : $lc_imageset_config_file"
    printf "%-8s%-80s\n" "[INFO]" "    - destination    : file://$lc_oc_mirror_work_dir"

    ### Execute the oc-mirror command with the specified configuration.
    printf "%-8s%-80s\n" "[INFO]" "--- Executing 'oc-mirror'..."
    "$PWD/oc-mirror" --v2 \
        --authfile      "$PULL_SECRET_FILE" \
        --log-level     "$OC_MIRROR_LOG_LEVEL" \
        --cache-dir     "$OC_MIRROR_CACHE_DIR" \
        --image-timeout "$OC_MIRROR_IMAGE_TIMEOUT" \
        --retry-times   "$OC_MIRROR_RETRY_TIMES" \
        --config        "$lc_imageset_config_file" \
        "file://$lc_oc_mirror_work_dir" || {
            printf "%-8s%-80s\n" "[ERROR]" "    'oc-mirror' command failed. Check the output above for details. Exiting..."
            exit 1
        }
}

### ---------------------------------------------------------------------------------
### Main Execution Logic
### ---------------------------------------------------------------------------------
### Parse OCP versions and catalogs from the configuration variables.
extract_ocp_versions
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

printf "%-8s%-80s\n" "[INFO]" "=== Starting Mirroring for OpenShift Operator Images ==="
### Loop through each OCP version and start the mirroring process.
for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        mirror_export_dirs+=("$oc_mirror_work_dir")

        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            ### Clean up previous temporary data if it exists to ensure a fresh run.
            printf "%-8s%-80s\n" "[INFO]" "--- Found existing 'working-dir' at '$oc_mirror_work_dir/working-dir'."
            printf "%-8s%-80s\n" "[INFO]" "    Removing existing 'working-dir' for a clean run..."
            rm -Rf "$oc_mirror_work_dir/working-dir/*"
        fi

        ### Ensure the ImageSet configuration file exists before attempting to mirror.
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        if [[ -f "$imageset_config_file" ]]; then
            printf "%-8s%-80s\n" "[INFO]" "--- Mirroring images for catalog '$catalog', OCP version '$major_minor'..."
            ### Call the function to mirror images using the specified configuration.
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
        else
            printf "%-8s%-80s\n" "[ERROR]" "--- ImageSet configuration file '$imageset_config_file' not found. Exiting..."
            exit 1
        fi
    done
done

### ---------------------------------------------------------------------------------
### Completion Summary
### ---------------------------------------------------------------------------------
### Log a final summary of the completed mirroring process, listing all
### directories where image sets were created.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Operator Image Mirroring Process Completed ==="
printf "%-8s%-80s\n" "[INFO]" "    Mirrored image sets are located in the following directories:"
for export_dir in "${mirror_export_dirs[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    - $export_dir"
done
echo ""