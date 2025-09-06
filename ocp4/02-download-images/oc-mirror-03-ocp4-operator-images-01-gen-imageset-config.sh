#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file' at $config_file. File or directory does not exist. Exited."
    exit 1
fi
source "$config_file"

### Validate critical environment variables
if [[ -z "$WORK_DIR" || -z "$PULL_SECRET_FILE" || -z "$log_dir" ]]; then
    echo "[ERROR] One or more required environment variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set. Exited."
    exit 1
fi

### Declare global arrays
unset log_files imageset_config_files
declare -a log_files imageset_config_files

### Validate operator channel info script
operator_channel_info_sh="$(dirname "$(realpath "$0")")/oc-mirror-03-ocp4-operator-images-00-operator-channel-info.sh"
if [[ ! -f "$operator_channel_info_sh" ]]; then
    log "ERROR" "Cannot access 'operator_channel_info_sh' at $operator_channel_info_sh. File or directory does not exist. Exited."
    exit 1
fi

### Pull and process catalog index
pull_catalog_index() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3"
    local lc_packages=""

    ### Log function invocation details
    log_echo ""
    log_echo "=============================="
    log "INFO" "pull_catalog_index()"
    log_echo "=============================="
    log "INFO" "PULL_OLM_INDEX_IMAGE : $PULL_OLM_INDEX_IMAGE"
    log "INFO" "  catalog_source_dir : $lc_catalog_source_dir"
    log "INFO" "       Catalog Index : $lc_catalog_index"
    log_echo "------------------------------"

    ### Create catalog source directory if it doesn't exist
    if [[ ! -d "$lc_catalog_source_dir" ]]; then
        log "INFO" "Creating catalog source directory: $lc_catalog_source_dir"
        mkdir -p "$lc_catalog_source_dir" || {
            log "ERROR" "Failed to create directory $lc_catalog_source_dir. Exited."
            exit 1
        }
        chmod 755 "$lc_catalog_source_dir"
        if [[ "$PULL_OLM_INDEX_IMAGE" == "false" ]]; then
            PULL_OLM_INDEX_IMAGE="true"
            log "INFO" "Updated PULL_OLM_INDEX_IMAGE to true"
        fi
    fi

    ### Pull catalog index if necessary
    if [[ "$PULL_OLM_INDEX_IMAGE" == "true" ]]; then
        podman rmi "$lc_catalog_index" 2>>"$log_file"
        if [[ -n "$(ls -A "$lc_catalog_source_dir")" ]]; then
            log "INFO" "rm -Rf $lc_catalog_source_dir/*"
            rm -Rf "$lc_catalog_source_dir"/*
        fi

        log_echo ""
        log "INFO" "Copying catalog data to '$lc_catalog_source_dir'"
        log_echo ""

        podman run \
            --user $(id -u):$(id -g) \
            --authfile "$PULL_SECRET_FILE" \
            -i --rm \
            -v "$lc_catalog_source_dir:/mnt:z" \
            --entrypoint /bin/sh "$lc_catalog_index" \
            -c "cp -R /configs/* /mnt/" 2>&1 | tee -a "$log_file"
    else
        log "INFO" "Using existing catalog data in $lc_catalog_source_dir"
        log "INFO" "Found JSON files: $(find "$lc_catalog_source_dir" -name "*.json" | wc -l)"
    fi
}

### Get default channel for an operator
get_defaultchannel_for_operator() {
    local lc_catalog_file="$1"
    if [[ ! -s "$lc_catalog_file" ]]; then
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    fi
    jq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Get all channels for an operator
get_channels_for_operator() {
    local lc_catalog_file="$1"
    if [[ ! -s "$lc_catalog_file" ]]; then
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    fi
    jq -r 'select(.schema == "olm.channel") | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Get versions available in a channel
get_versions_for_channel() {
    local lc_channel="$1" lc_catalog_file="$2"
    if [[ ! -s "$lc_catalog_file" ]]; then
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    fi
    jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Get the max version in a channel
get_maxversion_of_channel() {
    local lc_channel="$1" lc_catalog_file="$2"
    if [[ ! -s "$lc_catalog_file" ]]; then
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    fi
    jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' "$lc_catalog_file" | sort -Vr | head -n 1 2>/dev/null || echo ""
}

### Get version from bundle properties
get_properties_version() {
    local lc_full_version="$1" lc_catalog_file="$2"
    if [[ ! -s "$lc_catalog_file" ]]; then
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    fi
    jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Extract version number (remove package prefix and 'v')
get_extract_version() {
    local lc_input="$1"
    if [[ -z "$lc_input" ]]; then
        log "WARN" "Empty version input"
        echo ""
        return
    fi
    ### Remove package prefix (e.g., 'advanced-cluster-management.v', 'cluster-logging.v') and 'v'
    echo "$lc_input" | sed -E 's/^[a-zA-Z0-9_-]+\.v?//; s/^v//'
}

### Find matching versions
get_matching_versions() {
    local lc_versions="$1"
    shift
    local lc_specified_versions=("$@")
    unset lc_matching_versions_map
    local -A lc_matching_versions_map

    if [[ ${#lc_specified_versions[@]} -eq 0 ]]; then
        return
    fi

    for lc_ver in $lc_versions; do
        for lc_spec_ver in "${lc_specified_versions[@]}"; do
            if [[ "$lc_spec_ver" == "$lc_ver" ]]; then
                lc_matching_versions_map["$lc_ver"]=1
            fi
        done
    done
    if [[ ${#lc_matching_versions_map[@]} -gt 0 ]]; then
        mapfile -t lc_matching_versions < <(printf '%s\n' "${!lc_matching_versions_map[@]}" | sort -V)
        printf '%s\n' "${lc_matching_versions[@]}"
    fi
}

### Format string for YAML output
get_string() {
    local lc_string="$1"
    if [[ "$lc_string" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "'$lc_string'"
    else
        echo "$lc_string"
    fi
}

create_catalog_info() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3" lc_catalog_info_log="$4"
    local -a lc_operators

    ### Select operator array based on catalog type
    case "$lc_catalog" in
        "redhat")    lc_operators=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_operators=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_operators=("${COMMUNITY_OPERATORS[@]}");;
        *) log "ERROR" "Invalid catalog type '$lc_catalog'. Exited."; exit 1;;
    esac

    if [[ ${#lc_operators[@]} -eq 0 ]]; then
        log "ERROR" "No operators defined for ${lc_catalog}-operators catalog. Exited."
        exit 1
    fi

    log "INFO" "Processing ${#lc_operators[@]} operators for ${lc_catalog}-operators catalog"

    local lc_processed_packages=0
    for lc_package in "${lc_operators[@]}"; do
        if [[ -z "$lc_package" ]]; then
            log "WARN" "Empty package entry. Skipping..."
            continue
        fi

        ### Split package entry into name and versions
        IFS='|' read -r -a lc_version_parts <<< "$lc_package"
        lc_package_name="${lc_version_parts[0]}"
         
        local lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/catalog.json"
        if [[ ! -f "$lc_catalog_file" ]]; then
            lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/index.json"
        fi

        if [[ ! -f "$lc_catalog_file" ]]; then
            echo "No catalog file found for operator $lc_package_name at $lc_catalog_file. Skipping..."
            continue
        fi

        echo "=======================================================================" >> "$lc_catalog_info_log" 2>&1
        echo "Catalog : $lc_catalog_index"                                             >> "$lc_catalog_info_log" 2>&1
        echo "Operator: $lc_package_name"                                              >> "$lc_catalog_info_log" 2>&1
        echo "=======================================================================" >> "$lc_catalog_info_log" 2>&1
        bash "$operator_channel_info_sh" "$lc_catalog_file"                            >> "$lc_catalog_info_log" 2>&1
        echo ""                                                                        >> "$lc_catalog_info_log" 2>&1

        log "INFO" "Catalog Info: Path=$lc_catalog_info_log Operator=$lc_package_name"
    done
}

### Generate content for imageset-config.yaml
set_contents() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3" lc_imageset_config_file="$4"
    local -a lc_operators

    ### Select operator array based on catalog type
    case "$lc_catalog" in
        "redhat")    lc_operators=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_operators=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_operators=("${COMMUNITY_OPERATORS[@]}");;
        *) log "ERROR" "Invalid catalog type '$lc_catalog'. Exited."; exit 1;;
    esac

    if [[ ${#lc_operators[@]} -eq 0 ]]; then
        log "ERROR" "No operators defined for catalog $lc_catalog. Exited."
        exit 1
    fi

    local lc_processed_packages=0
    for lc_package in "${lc_operators[@]}"; do
        unset lc_operator_specified_versions
        unset lc_identical_channels
        unset lc_different_channels

        lc_is_min_version_added="false"

        local -A lc_identical_channels lc_different_channels
        if [[ -z "$lc_package" ]]; then
            log "WARN" "Empty package entry. Skipping..."
            continue
        fi

        ### Split package entry into name and versions
        IFS='|' read -r -a lc_version_parts <<< "$lc_package"
        lc_package_name="${lc_version_parts[0]}"
        mapfile -t lc_operator_specified_versions < <(printf '%s\n' "${lc_version_parts[@]:1}" | sort -Vr)
        if [[ ${#lc_operator_specified_versions[@]} -eq 1 ]] && [[ -z "${lc_operator_specified_versions[0]}" ]]; then
            unset lc_operator_specified_versions
        fi

        local lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/catalog.json"
        if [[ ! -f "$lc_catalog_file" ]]; then
            lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/index.json"
        fi
        if [[ ! -f "$lc_catalog_file" ]]; then
            log "WARN" "No catalog file found for operator '$lc_package_name' at $lc_catalog_file. Skipped."
            continue
        fi

        log_echo ""
        log_echo "-----------------------------------------------------------------------"
        log "INFO" "Catalog : $lc_catalog_index"
        log "INFO" "Operator: $lc_package_name"
        if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
            log "INFO" "Specified Versions : None"
        else
            log "INFO" "Specified Versions :"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        fi
        log_echo "-----------------------------------------------------------------------"

        lc_default_channel=$(get_defaultchannel_for_operator "$lc_catalog_file")
        if [[ -z "$lc_default_channel" ]]; then
            log "WARN" "No default channel found for $lc_package_name in $lc_catalog_file. Skipping..."
            continue
        fi
        lc_default_versions=$(get_versions_for_channel "$lc_default_channel" "$lc_catalog_file")
        lc_channels=$(get_channels_for_operator "$lc_catalog_file")

        log "INFO" "Default channel for $lc_package_name: $lc_default_channel"
        log "INFO" "Available channels:"
        echo "$lc_channels" | awk '{printf "            %s\n", $0}'

        mapfile -t lc_channels < <(get_channels_for_operator "$lc_catalog_file")
        for lc_channel in "${lc_channels[@]}"; do
            if [[ "$lc_channel" != "$lc_default_channel" ]]; then
                lc_channel_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
                if [[ "$lc_channel_versions" == "$lc_default_versions" ]]; then
                    lc_identical_channels["$lc_channel"]=1
                elif [[ "$lc_channel" != "candidate" ]]; then
                    lc_different_channels["$lc_channel"]=1
                fi
            fi
        done

        unset lc_matching_versions
        ### Matching Versions for Default Channel
        if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
            mapfile -t lc_matching_versions < <(get_matching_versions "$lc_default_versions" "${lc_operator_specified_versions[@]}")
            if [[ ${#lc_matching_versions[@]} -gt 0 ]]; then
                unset lc_temp_versions
                local -a lc_temp_versions
                for lc_version in "${lc_operator_specified_versions[@]}"; do
                    local lc_match_found=0
                    for lc_match_ver in "${lc_matching_versions[@]}"; do
                        if [[ "$lc_version" == "$lc_match_ver" ]]; then
                            lc_match_found=1
                            break
                        fi
                    done
                    if [[ $lc_match_found -eq 0 ]]; then
                        lc_temp_versions+=("$lc_version")
                    fi
                done
                unset lc_operator_specified_versions
                if [[ ${#lc_temp_versions[@]} -gt 0 ]]; then
                    declare -a lc_operator_specified_versions=("${lc_temp_versions[@]}")
                else
                    declare -a lc_operator_specified_versions
                fi
            fi
        fi

        log_echo "---------------------------------"
        log "INFO" "Total Number of Channels: $(echo "${#lc_channels[@]}")"
        if [[ ${#lc_identical_channels[@]} -eq 0 ]]; then
            log "INFO" "Channels with Identical Version List to Default Channel : None"
        else
            log "INFO" "Channels with Identical Version List to Default Channel : ${!lc_identical_channels[@]}"
        fi
        log_echo "---------------------------------"
        if [[ -z "${lc_matching_versions+x}" ]]; then
            log "INFO" "Matching versions: None"
        else
            log "INFO" "Matching versions:"
            log_echo "$(printf '            %s\n' "${lc_matching_versions[@]}")"
        fi
        if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
            log "INFO" "Remaining versions: None"
        else
            log "INFO" "Remaining versions:"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        fi

        cat <<EOF >> "$lc_imageset_config_file"
    - name: $lc_package_name
      channels:
EOF
        log "INFO" "***yaml*** defaultChannel: $lc_default_channel"
        cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_default_channel")
EOF
        if [[ ${#lc_matching_versions[@]} -gt 0 ]]; then
            lc_is_min_version_added="true"
            local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions[@]}" | sort -V | head -n 1)
            log "INFO" "***yaml*** Add minVersion to defaultChannel($lc_default_channel): raw=$lc_min_matching_version, extracted=$(get_extract_version "$lc_min_matching_version")"
            cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
        fi

        if [[ ${#lc_different_channels[@]} -gt 0 ]]; then
            log_echo "---------------------------------"
            if [[ ${#lc_different_channels[@]} -eq 0 ]]; then
                log "INFO" "Addable channels: None"
            else
                log "INFO" "Addable channels (${#lc_different_channels[@]}) :"
                log_echo "$(printf '            %s\n' "${!lc_different_channels[@]}" | sort -Vr)"
            fi
            log_echo "---------------------------------"

            unset lc_added_channels
            local -A lc_added_channels

            if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
                for lc_channel in $(printf '%s\n' "${!lc_different_channels[@]}" | sort -Vr); do
                    if [[ -z "${lc_added_channels[$lc_channel]}" ]]; then
                        local lc_channel_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
                        unset lc_matching_versions_channel
                        mapfile -t lc_matching_versions_channel < <(get_matching_versions "$lc_channel_versions" "${lc_operator_specified_versions[@]}")
                        if [[ ${#lc_matching_versions_channel[@]} -gt 0 ]]; then
                            lc_is_min_version_added="true"
                            log "INFO" "Channel: $lc_channel"
                            log "INFO" "Matching versions:"
                            log_echo "$(printf '            %s\n' "${lc_matching_versions_channel[@]}")"
                            unset lc_temp_versions
                            local -a lc_temp_versions
                            for lc_version in "${lc_operator_specified_versions[@]}"; do
                                local lc_match_found=0
                                for lc_match_ver in "${lc_matching_versions_channel[@]}"; do
                                    if [[ "$lc_version" == "$lc_match_ver" ]]; then
                                        lc_match_found=1
                                        break
                                    fi
                                done
                                if [[ $lc_match_found -eq 0 ]]; then
                                    lc_temp_versions+=("$lc_version")
                                fi
                            done
                            unset lc_operator_specified_versions
                            if [[ ${#lc_temp_versions[@]} -gt 0 ]]; then
                                declare -a lc_operator_specified_versions=("${lc_temp_versions[@]}")
                            else
                                declare -a lc_operator_specified_versions
                            fi
                            if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                                log "INFO" "Remaining versions : None"
                            else
                                log "INFO" "Remaining versions :"
                                log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                            fi
                            log "INFO" "***yaml*** Add Channel: $(get_string "$lc_channel")"
                            cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_channel")
EOF
                            local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions_channel[@]}" | sort -V | head -n 1)
                            log "INFO" "***yaml*** Add minVersion to Channel($lc_channel): raw=$lc_min_matching_version, extracted=$(get_extract_version "$lc_min_matching_version")"
                            cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
                            lc_added_channels["$lc_channel"]=1
                        fi
                    fi
                done
            fi
        else
            ### Log remaining versions if no different channels exist
            if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
                log "WARN" "Specified versions not found in catalog for operator '$lc_package_name' in OCP $OCP_VERSIONS (only default channel '$lc_default_channel' available)."
                log "WARN" "Remaining versions:"
                log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                log "WARN" "Please verify the version specifications or check compatibility with OCP $OCP_VERSIONS."
                log_echo ""
            fi
        fi
        ((lc_processed_packages++))
    done

    if [[ $lc_processed_packages -eq 0 ]]; then
        log "ERROR" "No packages were processed successfully in set_contents(). Check catalog data in $lc_catalog_source_dir. Exited."
        exit 1
    fi
}

### Main Logic
log "INFO" "Starting script with OCP_VERSIONS: $OCP_VERSIONS"
extract_ocp_versions
log "INFO" "After extract_ocp_versions, MAJOR_MINOR_ARRAY: ${MAJOR_MINOR_ARRAY[*]}"

if [[ ${#MAJOR_MINOR_ARRAY[@]} -eq 0 ]]; then
    log "ERROR" "MAJOR_MINOR_ARRAY is empty after extract_ocp_versions. Exited."
    exit 1
fi

unset catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"
log "INFO" "Catalogs: ${catalogs[*]}"

if [[ ${#catalogs[@]} -eq 0 ]]; then
    log "ERROR" "No catalogs found in OLM_CATALOGS. Exitied."
    exit 1
fi

for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        catalog_source_dir="$WORK_DIR/oc-mirror/index/$catalog/$major_minor"
        catalog_index="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
        catalog_info_log="$log_dir/olm-${catalog}-catalog-channel-info-${major_minor}.log"
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        imageset_config_files+=("$imageset_config_file")
        log_files+=("$catalog_info_log")

        if [[ -d "$oc_mirror_work_dir" ]]; then
            chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir."
 
            if ! rm -Rf "$oc_mirror_work_dir"; then
                log "ERROR" "Failed to remove $oc_mirror_work_dir. Exited."
                exit 1
            fi
        fi

        if ! mkdir -p "$oc_mirror_work_dir"; then
            log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exited."
            exit 1
        fi

        pull_catalog_index  "$catalog" "$catalog_source_dir" "$catalog_index"
        create_catalog_info "$catalog" "$catalog_source_dir" "$catalog_index" "$catalog_info_log"

        cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: $catalog_index
    packages:
EOF
        set_contents "$catalog" "$catalog_source_dir" "$catalog_index" "$imageset_config_file"
    done
done

### Log completion
log_echo ""
log "INFO" "Completed generating ImageSet configuration."
log "INFO" "Log Files:"
for file in "$log_file" "${log_files[@]}"; do
    log "INFO" "  $file"
done
log "INFO" "Generated ImageSet Configuration Files:"
for file in "${imageset_config_files[@]}"; do
    log "INFO" "  $file"
done
log_echo ""