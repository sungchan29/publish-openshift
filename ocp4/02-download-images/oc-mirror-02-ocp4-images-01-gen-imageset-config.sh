#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate OpenShift ImageSet Configuration for OCP
### ---------------------------------------------------------------------------------
### This script automates the creation of ImageSetConfiguration manifests for
### mirroring specific OpenShift Container Platform (OCP) release images.

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

### ---------------------------------------------------------------------------------
### Generate ImageSetConfiguration YAML
### ---------------------------------------------------------------------------------
### Defines a function to generate the ImageSetConfiguration manifest for a given version.
generate_imageset_config() {
    local lc_output_file="$1"
    shift
    local lc_version_list=("$@")

    printf "%-8s%-80s\n" "[INFO]" "    Creating initial ImageSetConfiguration file ..."
    ### Initialize the YAML file with its header.
    cat << 'EOF' > "$lc_output_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
EOF

    ### Declare associative arrays to process version details.
    declare -A min_versions max_versions
    declare -a channel_mappings

    minVersions=()
    maxVersions=()
    channelMappings=()

    ### Process the provided versions to find the min and max patch number per major.minor version.
    ### Note: This script calls the function with one version at a time, so min and max will be the same.
    for version in "${lc_version_list[@]}"; do
        if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)\.([0-9]+(-[a-z0-9]+)?)$ ]]; then
            printf "%-8s%-80s\n" "[WARN]" "    Skipping invalid version format: $version."
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

    if [[ ${#min_versions[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "    No valid versions were processed to generate ImageSetConfiguration. Exiting..."
        exit 1
    fi

    ### Generate a channel entry for each major.minor version found.
    for lc_major_minor in "${!min_versions[@]}"; do
        local lc_min_version="${lc_major_minor}.${min_versions[$lc_major_minor]}"
        local lc_max_version="${lc_major_minor}.${max_versions[$lc_major_minor]}"

        local lc_selected_channel
        lc_selected_channel=$(get_channel_by_version "$lc_max_version") || { printf "%-8s%-80s\n" "[ERROR]" "    Failed to get channel for version '$lc_max_version'. Exiting..."; exit 1; }

        local lc_min_channel
        lc_min_channel=$(get_channel_by_version "$lc_min_version") || { printf "%-8s%-80s\n" "[ERROR]" "    Failed to get channel for version '$lc_min_version'. Exiting..."; exit 1; }

        if [[ "$lc_min_channel" != "$lc_selected_channel" ]]; then
            printf "%-8s%-80s\n" "[WARN]" "      - Channel mismatch detected: minVersion ($lc_min_version is in '$lc_min_channel') vs maxVersion ($lc_max_version is in '$lc_selected_channel'). Using channel '$lc_selected_channel'."
        fi

        channel_mappings+=("$lc_selected_channel -> min: $lc_min_version, max: $lc_max_version")
        printf "%-8s%-80s\n" "[INFO]" "      - YAML: Adding channel '$lc_selected_channel' for version range $lc_min_version to $lc_max_version."

        ### Append the channel entry to the YAML file.
        if [[ "$lc_min_version" == "$lc_max_version" ]]; then
            cat << EOF >> "$lc_output_file"
    - name: $lc_selected_channel
      minVersion: $lc_min_version
      maxVersion: $lc_max_version
EOF
        else
            cat << EOF >> "$lc_output_file"
    - name: $lc_selected_channel
      minVersion: $lc_min_version
      maxVersion: $lc_max_version
      shortestPath: true
EOF
        fi
    done
}

### ---------------------------------------------------------------------------------
### Main Logic
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting OCP ImageSet configuration generation ==="

declare -a imageset_config_files
imageset_config_files=()

### Iterate through each OCP version specified in the configuration.
for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "--- Processing OCP Version: $major_minor_patch"
    printf "%-8s%-80s\n" "[INFO]" "    Preparing to generate ImageSetConfiguration for OCP version '$major_minor_patch'..."

    ### Define the working directory for the current OCP version.
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$major_minor_patch"

    ### Clean up the working directory if it already exists.
    if [[ -d "$oc_mirror_work_dir" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    Cleaning up existing directory: '$oc_mirror_work_dir'..."
        chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || printf "%-8s%-80s\n" "[WARN]" "    Failed to set write permissions on '$oc_mirror_work_dir'. Continuing cleanup."
        rm -Rf "$oc_mirror_work_dir" || {
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to delete directory '$oc_mirror_work_dir'. Check permissions. Exiting..."
            exit 1
        }
    fi

    ### Create a new working directory for the current OCP version.
    printf "%-8s%-80s\n" "[INFO]" "    Creating working directory for OCP version '$major_minor_patch'..."
    mkdir -p "$oc_mirror_work_dir" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to create directory '$oc_mirror_work_dir'. Exiting..."
        exit 1
    }

    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    imageset_config_files+=("$imageset_config_file")

    ### Generate the ImageSetConfiguration file for the current version.
    generate_imageset_config "$imageset_config_file" "$major_minor_patch"
done

echo ""
printf "%-8s%-80s\n" "[INFO]" "=== OpenShift Release ImageSet Configuration Generation Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Generated Files:"
for file in "${imageset_config_files[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    - ImageSet Config: $file"
done
echo ""