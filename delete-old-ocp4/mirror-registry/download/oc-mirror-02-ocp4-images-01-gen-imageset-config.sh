#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

### Function to generate ImageSetConfiguration file
generate_imageset_config() {
    local lc_output_file="$1"
    shift
    local lc_version_list=("$@")

    ### Write YAML header
    cat << 'EOF' > "$lc_output_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
EOF

    ### Initialize associative arrays for version tracking
    unset min_versions max_versions
    declare -A min_versions max_versions

    ### Process versions to determine min/max and channel types
    for version in "${lc_version_list[@]}"; do
        ### Extract major.minor and patch versions
        local lc_major_minor=$(echo "$version" | cut -d '.' -f 1,2)
        local lc_patch=$(echo "$version" | cut -d '.' -f 3)

        ### Skip if version parsing fails
        if [[ -z "$lc_major_minor" ]] || [[ -z "$lc_patch" ]]; then
            log "WARN" "Skipping invalid version format: $version"
            continue
        fi

        ### Track min and max versions for each major.minor version
        if [[ -z "${min_versions[$lc_major_minor]}" ]] || (( lc_patch < ${min_versions[$lc_major_minor]} )); then
            min_versions[$lc_major_minor]=$lc_patch
        fi
        if [[ -z "${max_versions[$lc_major_minor]}" ]] || (( lc_patch > ${max_versions[$lc_major_minor]} )); then
            max_versions[$lc_major_minor]=$lc_patch
        fi
    done

    ### Append version information to the ImageSetConfiguration file
    for lc_major_minor in "${!min_versions[@]}"; do
        local lc_min_version="${lc_major_minor}.${min_versions[$lc_major_minor]}"
        local lc_max_version="${lc_major_minor}.${max_versions[$lc_major_minor]}"
        local lc_selected_channel=$(get_channel_by_version "$lc_max_version")
        if [[ "$lc_min_version" == "$lc_max_version" ]]; then
            cat << EOF >> "$lc_output_file"
    - name: $lc_selected_channel
      minVersion: $lc_min_version
      maxVersion: $lc_max_version
EOF
        ### Add shortestPath only if min_version and max_version are different
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

###
### Main logic
###

extract_ocp_versions

if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d "$oc_mirror_work_dir" ]]; then
        rm -Rf "$oc_mirror_work_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to remove existing directory $oc_mirror_work_dir. Exiting..."
            exit 1
        fi
    fi
    mkdir -p "$oc_mirror_work_dir"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
        exit 1
    fi

    ### Aggregated mode: Single file with all versions
    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    imageset_config_files+=("$imageset_config_file")

    generate_imageset_config "$imageset_config_file" "${OCP_VERSION_ARRAY[@]}"
    log "INFO" "Generated $imageset_config_file"
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    oc_mirror_work_dir="$WORK_DIR/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d "$oc_mirror_work_dir" ]]; then
        rm -Rf "$oc_mirror_work_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to remove existing directory $oc_mirror_work_dir. Exiting..."
            exit 1
        fi
    fi
    mkdir -p "$oc_mirror_work_dir"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
        exit 1
    fi

    ### Generate files incrementally
    for ((i=0; i<${#OCP_VERSION_ARRAY[@]}; i++)); do
        current_versions=("${OCP_VERSION_ARRAY[@]:0:$((i+1))}")
        version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

        imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"
        imageset_config_files+=("$imageset_config_file")

        generate_imageset_config "$imageset_config_file" "${current_versions[@]}"
        log "INFO" "Generated $imageset_config_file"
    done
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY/$major_minor_patch"
        if [[ ! -d "$oc_mirror_work_dir" ]]; then
            mkdir -p "$oc_mirror_work_dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
                exit 1
            fi
        fi
        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            rm -Rf "$oc_mirror_work_dir/working-dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to remove working-dir in $oc_mirror_work_dir. Exiting..."
                exit 1
            fi
        fi

        ### Individual mode: One file per version
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        imageset_config_files+=("$imageset_config_file")
        
        generate_imageset_config "$imageset_config_file" "$major_minor_patch"
        log "INFO" "Generated $imageset_config_file"
    done
else
    ### Handle invalid MIRROR_STRATEGY value
    log "ERROR" "Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'. Exiting..."
    exit 1
fi

log_echo ""
log      "INFO" "ImageSet configuration generation completed."
log      "INFO" "Log File: $log_file"
log_echo ""
log      "INFO" "Generated ImageSet Configuration Files:"
for file in "${imageset_config_files[@]}"; do
    log  "INFO" "  $file"
done
