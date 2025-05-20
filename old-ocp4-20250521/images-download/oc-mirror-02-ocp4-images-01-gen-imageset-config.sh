#!/bin/bash

### Source configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    log "ERROR" "Cannot access config file at $config_file. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

### Function to generate ImageSetConfiguration YAML
generate_imageset_config() {
    local lc_output_file="$1"
    shift
    local lc_version_list=("$@")

    ### Initialize YAML header
    cat << 'EOF' > "$lc_output_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
EOF

    ### Declare associative arrays for min/max versions and channel mappings
    unset min_versions max_versions channel_mappings
    declare -A min_versions max_versions
    declare -a channel_mappings

    ### Process versions to determine min/max per major.minor
    for version in "${lc_version_list[@]}"; do
        if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)\.([0-9]+(-[a-z0-9]+)?)$ ]]; then
            log "WARN" "Skipping invalid version format: $version"
            continue
        fi
        local lc_major_minor="${BASH_REMATCH[1]}"
        local lc_patch="${BASH_REMATCH[2]}"
        local lc_patch_num="${lc_patch%%-*}"

        ### Update min/max versions
        if [[ -z "${min_versions[$lc_major_minor]}" ]] || (( lc_patch_num < ${min_versions[$lc_major_minor]} )); then
            min_versions[$lc_major_minor]=$lc_patch_num
        fi
        if [[ -z "${max_versions[$lc_major_minor]}" ]] || (( lc_patch_num > ${max_versions[$lc_major_minor]} )); then
            max_versions[$lc_major_minor]=$lc_patch_num
        fi
    done

    ### Validate processed versions
    if [[ ${#min_versions[@]} -eq 0 ]]; then
        log "ERROR" "No valid versions processed for ImageSetConfiguration. Exiting..."
        exit 1
    fi

    ### Generate channel entries and collect mappings
    for lc_major_minor in "${!min_versions[@]}"; do
        local lc_min_version="${lc_major_minor}.${min_versions[$lc_major_minor]}"
        local lc_max_version="${lc_major_minor}.${max_versions[$lc_major_minor]}"
        local lc_selected_channel=$(get_channel_by_version "$lc_max_version")
        if [[ -z "$lc_selected_channel" ]]; then
            log "ERROR" "Failed to determine channel for version $lc_max_version. Exiting..."
            exit 1
        fi
        local lc_min_channel=$(get_channel_by_version "$lc_min_version")
        if [[ "$lc_min_channel" != "$lc_selected_channel" ]]; then
            log "WARN" "Channel mismatch: minVersion ($lc_min_version, $lc_min_channel) vs maxVersion ($lc_max_version, $lc_selected_channel). Using $lc_selected_channel."
        fi
        ### Store channel mapping for logging
        channel_mappings+=("$lc_selected_channel=$lc_min_version $lc_max_version")
        ### Log channel and version details
        log "INFO" "Adding channel: $lc_selected_channel, minVersion: $lc_min_version, maxVersion: $lc_max_version"
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

    ### Log channel mappings in sorted order
    log "INFO" "Channel mappings:"
    if [[ ${#channel_mappings[@]} -gt 0 ]]; then
        ### Sort channel mappings alphabetically
        IFS=$'\n' sorted_mappings=($(sort <<<"${channel_mappings[*]}"))
        unset IFS
        for mapping in "${sorted_mappings[@]}"; do
            log "INFO" "       $mapping"
        done
    else
        log "WARN" "       No channel mappings generated."
    fi
}

###
### Main logic
###
### Extract OCP versions
extract_ocp_versions

### Initialize imageset_config_files array
unset imageset_config_files
declare -a imageset_config_files

if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    ### Aggregated mode: Generate single YAML file for all versions
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d "$oc_mirror_work_dir" ]]; then
        ### Remove existing directory with permissions fix
        log "INFO" "Removing existing directory $oc_mirror_work_dir"
        chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
        rm -Rf "$oc_mirror_work_dir" || {
            log "ERROR" "Failed to delete directory $oc_mirror_work_dir. Exiting..."
            exit 1
        }
    fi
    ### Create working directory
    mkdir -p "$oc_mirror_work_dir" || {
        log "ERROR" "Failed to create directory $oc_mirror_work_dir: $?. Exiting..."
        exit 1
    }

    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    imageset_config_files+=("$imageset_config_file")

    generate_imageset_config "$imageset_config_file" "${OCP_VERSION_ARRAY[@]}"
    log "INFO" "Generated $imageset_config_file"
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    ### Incremental mode: Generate YAML files incrementally
    oc_mirror_work_dir="$WORK_DIR/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d "$oc_mirror_work_dir" ]]; then
        ### Remove existing directory with permissions fix
        log "INFO" "Removing existing directory $oc_mirror_work_dir"
        chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
        rm -Rf "$oc_mirror_work_dir" || {
            log "ERROR" "Failed to delete directory $oc_mirror_work_dir. Exiting..."
            exit 1
        }
    fi
    ### Create working directory
    mkdir -p "$oc_mirror_work_dir" || {
        log "ERROR" "Failed to create directory $oc_mirror_work_dir: $?. Exiting..."
        exit 1
    }

    for ((i=0; i<${#OCP_VERSION_ARRAY[@]}; i++)); do
        current_versions=("${OCP_VERSION_ARRAY[@]:0:$((i+1))}")
        version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

        imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"
        imageset_config_files+=("$imageset_config_file")

        generate_imageset_config "$imageset_config_file" "${current_versions[@]}"
        log "INFO" "Generated $imageset_config_file"
    done
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    ### Individual mode: Generate one YAML file per version
    for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY/$major_minor_patch"
        if [[ -d "$oc_mirror_work_dir" ]]; then
            ### Remove existing directory with permissions fix
            log "INFO" "Removing existing directory $oc_mirror_work_dir"
            chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
            rm -Rf "$oc_mirror_work_dir" || {
                log "ERROR" "Failed to delete directory $oc_mirror_work_dir. Exiting..."
                exit 1
            }
        fi
        ### Create working directory
        mkdir -p "$oc_mirror_work_dir" || {
            log "ERROR" "Failed to create directory $oc_mirror_work_dir: $?. Exiting..."
            exit 1
        }

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

### Log completion of ImageSet configuration generation
log_echo ""
log "INFO" "ImageSet configuration generation completed."
log "INFO" "Log File: $log_file"
log_echo ""
log "INFO" "Generated ImageSet Configuration Files:"
for file in "${imageset_config_files[@]}"; do
    log "INFO" "  $file"
done
log_echo ""