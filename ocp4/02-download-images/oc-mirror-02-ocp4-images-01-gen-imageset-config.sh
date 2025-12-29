#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate OpenShift ImageSet Configuration for OCP
### ---------------------------------------------------------------------------------
### This script automates the creation of ImageSetConfiguration manifests for
### mirroring specific OpenShift Container Platform (OCP) release images.
### It reads configuration from 'oc-mirror-00-config-setup.sh'.

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

### Extract OCP versions using logic from 00 script
printf "%-8s%-80s\n" "[INFO]" "    Verifying OpenShift Versions..."
# This function populates OCP_VERSION_ARRAY based on OCP_VERSIONS string
extract_ocp_versions

if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No valid OCP versions found. Check 'OCP_VERSIONS' in config." >&2
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### ---------------------------------------------------------------------------------
### 3. Generator Function
### ---------------------------------------------------------------------------------

### Function to generate the ImageSetConfiguration manifest
generate_imageset_config() {
    local lc_output_file="$1"
    shift
    local lc_version_list=("$@")

    printf "%-8s%-80s\n" "[INFO]" "    Generating YAML: $(basename "$lc_output_file")"

    ### Initialize the YAML file with its header.
    ### Using v1alpha2 as the standard stable API version.
    cat << EOF > "$lc_output_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
EOF

    ### Declare associative arrays to process version details.
    declare -A min_versions max_versions

    ### Process the provided versions (In this logic, it's always single version per file)
    for version in "${lc_version_list[@]}"; do
        if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)\.([0-9]+(-[a-z0-9]+)?)$ ]]; then
            printf "%-8s%-80s\n" "[WARN]" "        Skipping invalid version format: $version."
            continue
        fi
        local lc_major_minor="${BASH_REMATCH[1]}"
        local lc_patch="${BASH_REMATCH[2]}"
        local lc_patch_num="${lc_patch%%-*}"

        if [[ ! -v "min_versions[$lc_major_minor]" ]] || (( lc_patch_num < min_versions[$lc_major_minor] )); then
            min_versions[$lc_major_minor]=$lc_patch_num
        fi
        if [[ ! -v "max_versions[$lc_major_minor]" ]] || (( lc_patch_num > max_versions[$lc_major_minor] )); then
            max_versions[$lc_major_minor]=$lc_patch_num
        fi
    done

    ### Generate a channel entry for each major.minor version found.
    for lc_major_minor in "${!min_versions[@]}"; do
        local lc_min_version="${lc_major_minor}.${min_versions[$lc_major_minor]}"
        local lc_max_version="${lc_major_minor}.${max_versions[$lc_major_minor]}"

        local lc_selected_channel
        lc_selected_channel=$(get_channel_by_version "$lc_max_version") || {
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to get channel for version '$lc_max_version'." >&2
            exit 1
        }

        printf "%-8s%-80s\n" "[INFO]" "        -> Adding Channel: $lc_selected_channel"
        printf "%-8s%-80s\n" "[INFO]" "           Min: $lc_min_version | Max: $lc_max_version (Pinned)"

        ### Append the channel entry to the YAML file.
        ### shortestPath: true ensures we minimize the number of images (though min=max makes it 1 anyway)
        cat << EOF >> "$lc_output_file"
    - name: $lc_selected_channel
      minVersion: $lc_min_version
      maxVersion: $lc_max_version
EOF
    done
}

### ---------------------------------------------------------------------------------
### 4. Main Logic
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Configuration Generation ==="

declare -a generated_files=()

### Iterate through each OCP version specified in the configuration.
### This Loop guarantees separate files for 4.18.17, 4.19.17, and 4.20.4
for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "--- Processing OCP Version: $major_minor_patch ---"

    ### Define the working directory for the current OCP version.
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$major_minor_patch"

    ### Clean up the working directory if it already exists.
    if [[ -d "$oc_mirror_work_dir" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    Cleaning up existing directory..."
        chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || true
        rm -rf "$oc_mirror_work_dir"
    fi

    ### Create a new working directory.
    mkdir -p "$oc_mirror_work_dir" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to create directory: $oc_mirror_work_dir" >&2
        exit 1
    }

    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    generated_files+=("$imageset_config_file")

    ### Generate the ImageSetConfiguration file.
    generate_imageset_config "$imageset_config_file" "$major_minor_patch"
done

### ---------------------------------------------------------------------------------
### 5. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Generation Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Generated ImageSetConfiguration files:"
for file in "${generated_files[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    - $file"
done
echo ""