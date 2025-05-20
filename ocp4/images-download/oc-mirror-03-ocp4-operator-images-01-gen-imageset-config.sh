#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file' at $config_file. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

### Validate critical environment variables
if [[ -z "$WORK_DIR" || -z "$PULL_SECRET_FILE" || -z "$log_dir" ]]; then
    echo "[ERROR] One or more required environment variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set. Exiting..."
    exit 1
fi

### Declare global arrays
unset log_files imageset_config_files
declare -a log_files imageset_config_files

### Validate operator channel info script
operator_channel_info_sh="$(dirname "$(realpath "$0")")/oc-mirror-03-ocp4-operator-images-00-operator-channel-info.sh"
if [[ ! -f "$operator_channel_info_sh" ]]; then
    log "ERROR" "Cannot access 'operator_channel_info_sh' at $operator_channel_info_sh. File or directory does not exist. Exiting..."
    exit 1
fi

### Pull and process catalog index
pull_catalog_index() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3" lc_log_file="$4"
    local lc_exists=0 lc_packages=""

    ### Add log file to global array if not already present
    for existing_file in "${log_files[@]}"; do
        [[ "$existing_file" == "$lc_log_file" ]] && lc_exists=1 && break
    done
    [[ $lc_exists -eq 0 ]] && log_files+=("$lc_log_file")

    ### Log function invocation details
    log_echo "------------------------------"
    log "INFO" "pull_catalog_index()"
    log_echo "------------------------------"
    log "INFO" "     MIRROR_STRATEGY : $MIRROR_STRATEGY"
    log "INFO" "PULL_OLM_INDEX_IMAGE : $PULL_OLM_INDEX_IMAGE"
    log "INFO" "  catalog_source_dir : $lc_catalog_source_dir"
    log "INFO" "       Catalog Index : $lc_catalog_index"
    log "INFO" "            Log File : "
    log "INFO" "                       $log_file"
    log "INFO" "                       $lc_log_file"
    log_echo "------------------------------"

    ### Create catalog source directory if it doesn't exist
    if [[ ! -d "$lc_catalog_source_dir" ]]; then
        log "INFO" "Creating catalog source directory: $lc_catalog_source_dir"
        mkdir -p "$lc_catalog_source_dir" || {
            log "ERROR" "Failed to create directory $lc_catalog_source_dir. Exiting..."
            exit 1
        }
        chmod 755 "$lc_catalog_source_dir"
        PULL_OLM_INDEX_IMAGE="true"
    fi

    ### Pull catalog index if necessary
    if [[ "$PULL_OLM_INDEX_IMAGE" == "true" || ! -d "$lc_catalog_source_dir" || -z "$(find "$lc_catalog_source_dir" -name "*.json")" ]]; then
        log "INFO" "Catalog data missing, invalid, or PULL_OLM_INDEX_IMAGE is true. Pulling catalog index..."
        podman rmi "$lc_catalog_index" 2>>"$log_file" || log "WARN" "Failed to remove existing image $lc_catalog_index. Continuing..."
        [[ -n "$(ls -A "$lc_catalog_source_dir")" ]] && {
            log "INFO" "Clearing existing catalog data in $lc_catalog_source_dir"
            rm -Rf "$lc_catalog_source_dir"/* || {
                log "ERROR" "Failed to clear $lc_catalog_source_dir. Exiting..."
                exit 1
            }
        }

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
        [[ ${PIPESTATUS[0]} -ne 0 ]] && {
            log "ERROR" "Failed to pull catalog index image $lc_catalog_index. Check $log_file for details. Exiting..."
            exit 1
        }
    else
        log "INFO" "Using existing catalog data in $lc_catalog_source_dir"
        log "INFO" "Found JSON files: $(find "$lc_catalog_source_dir" -name "*.json" | wc -l)"
    fi

    ### Process catalog data
    if [[ -d "$lc_catalog_source_dir" && -n "$(ls -A "$lc_catalog_source_dir")" ]]; then
        log_echo_operator_info "[INFO] [$(date +"%Y-%m-%d %H:%M:%S")] " "new" "$lc_log_file"
        mapfile -t lc_packages < <(find "$lc_catalog_source_dir" -maxdepth 1 -type d -not -path "$lc_catalog_source_dir" -exec basename {} \;)
        log_echo_operator_info "" "" "$lc_log_file"

        [[ -z "$lc_packages" ]] && {
            log "ERROR" "No packages found in $lc_catalog_source_dir. Exiting..."
            exit 1
        }

        log "INFO" "Found packages:"
        log_echo "$(printf '%s\n' "${lc_packages[@]}")"
        log_echo ""

        for lc_package_name in "${lc_packages[@]}"; do
            log_echo_operator_info "=======================================================================" "" "$lc_log_file"
            log_operator_info "INFO" "Catalog : $lc_catalog_index" "$lc_log_file"
            log_operator_info "INFO" "Operator: $lc_package_name" "$lc_log_file"
            log_echo_operator_info "=======================================================================" "" "$lc_log_file"

            local lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/catalog.json"
            [[ ! -f "$lc_catalog_file" ]] && lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/index.json"
            [[ ! -f "$lc_catalog_file" ]] && {
                log "WARN" "No catalog file found for operator $lc_package_name at $lc_catalog_file. Skipping..."
                continue
            }
            log "INFO" "Processing catalog file: $lc_catalog_file"
            bash "$operator_channel_info_sh" "$lc_catalog_file" >> "$lc_log_file" 2>&1 || log "WARN" "Failed to process catalog file $lc_catalog_file. Continuing..."
            log_echo_operator_info "" "" "$lc_log_file"
        done
    else
        log "ERROR" "No catalog data found in $lc_catalog_source_dir. Exiting..."
        exit 1
    fi
}

### Get default channel for an operator
get_defaultchannel_for_operator() {
    local lc_catalog_file="$1"
    [[ ! -s "$lc_catalog_file" ]] && {
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    }
    jq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Get all channels for an operator
get_channels_for_operator() {
    local lc_catalog_file="$1"
    [[ ! -s "$lc_catalog_file" ]] && {
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    }
    jq -r 'select(.schema == "olm.channel") | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Get versions available in a channel
get_versions_for_channel() {
    local lc_channel="$1" lc_catalog_file="$2"
    [[ ! -s "$lc_catalog_file" ]] && {
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    }
    jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Get the highest version in a channel
get_maxversion_of_channel() {
    local lc_channel="$1" lc_catalog_file="$2"
    [[ ! -s "$lc_catalog_file" ]] && {
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    }
    jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' "$lc_catalog_file" | sort -Vr | head -n 1 2>/dev/null || echo ""
}

### Get version from bundle properties
get_properties_version() {
    local lc_full_version="$1" lc_catalog_file="$2"
    [[ ! -s "$lc_catalog_file" ]] && {
        log "WARN" "Catalog file $lc_catalog_file is empty or does not exist"
        echo ""
        return
    }
    jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Extract version number (remove package prefix and 'v')
get_extract_version() {
    local lc_input="$1"
    [[ -z "$lc_input" ]] && {
        log "WARN" "Empty version input"
        echo ""
        return
    }
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

    [[ ${#lc_specified_versions[@]} -eq 0 ]] && return

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

### Determine the highest channel
get_highest_channel() {
    local lc_channels="$1" lc_catalog_file="$2"
    local lc_max_version="" lc_max_channel="" lc_versions="" lc_extract_ver=""

    while IFS=$'\n' read -r lc_channel; do
        [[ -n "$lc_channel" ]] || continue
        lc_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
        for lc_ver in $lc_versions; do
            [[ -n "$lc_ver" ]] || continue
            lc_extract_ver="$(get_extract_version "$lc_ver")"
            if [[ -z "$lc_max_version" || "$(printf '%s\n%s' "$lc_extract_ver" "$lc_max_version" | sort -Vr | head -n 1)" == "$lc_extract_ver" ]]; then
                lc_max_version="$lc_extract_ver"
                lc_max_channel="$lc_channel"
            fi
        done
    done <<< "$(echo "$lc_channels" | tr ' ' '\n' | sort -Vr)"
    echo "$lc_max_channel"
}

### Format string for YAML output
get_string() {
    local lc_string="$1"
    [[ "$lc_string" =~ ^[0-9]+(\.[0-9]+)*$ ]] && echo "'$lc_string'" || echo "$lc_string"
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
        *) log "ERROR" "Invalid catalog type '$lc_catalog'. Exiting..."; exit 1;;
    esac

    [[ ${#lc_operators[@]} -eq 0 ]] && {
        log "ERROR" "No operators defined for catalog $lc_catalog. Exiting..."
        exit 1
    }

    log_echo ""
    log "INFO" "Processing ${#lc_operators[@]} operators for catalog $lc_catalog"
    log_echo ""

    local lc_processed_packages=0
    for lc_package in "${lc_operators[@]}"; do
        lc_is_min_version_added="false"
        lc_is_highest_channel_added="false"

        [[ -z "$lc_package" ]] && {
            log "WARN" "Empty package entry. Skipping..."
            continue
        }
        [[ ! "$lc_package" =~ ^[^|]+\|.+$ ]] && {
            log "WARN" "Invalid package format: $lc_package. Expected 'package_name|version...'. Skipping..."
            continue
        }

        ### Split package entry into name and versions
        IFS='|' read -r -a lc_version_parts <<< "$lc_package"
        lc_package_name="${lc_version_parts[0]}"
        unset lc_operator_specified_versions
        mapfile -t lc_operator_specified_versions < <(printf '%s\n' "${lc_version_parts[@]:1}" | sort -Vr)

        local lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/catalog.json"
        [[ ! -f "$lc_catalog_file" ]] && lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/index.json"
        [[ ! -f "$lc_catalog_file" ]] && {
            log "WARN" "No catalog file found for operator '$lc_package_name' at $lc_catalog_file. Skipping..."
            continue
        }

        log_echo "======================================================================="
        log "INFO" "Catalog : $lc_catalog_index"
        log "INFO" "Operator: $lc_package_name"
        [[ ${#lc_operator_specified_versions[@]} -eq 0 ]] && log "INFO" "Specified Versions : None" || {
            log "INFO" "Specified Versions :"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        }
        log_echo "======================================================================="

        lc_default_channel=$(get_defaultchannel_for_operator "$lc_catalog_file")
        [[ -z "$lc_default_channel" ]] && {
            log "WARN" "No default channel found for $lc_package_name in $lc_catalog_file. Skipping..."
            continue
        }
        lc_default_versions=$(get_versions_for_channel "$lc_default_channel" "$lc_catalog_file")
        lc_channels=$(get_channels_for_operator "$lc_catalog_file")

        log "INFO" "Default channel for $lc_package_name: $lc_default_channel"
        log "INFO" "Available channels:"
        echo "$lc_channels" | awk '{printf "            %s\n", $0}'

        unset lc_identical_channels lc_different_channels
        local -A lc_identical_channels lc_different_channels

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

        ### Matching Versions for Default Channel
        if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
            unset lc_matching_versions
            mapfile -t lc_matching_versions < <(get_matching_versions "$lc_default_versions" "${lc_operator_specified_versions[@]}")
            if [[ ${#lc_matching_versions[@]} -gt 0 ]]; then
                unset lc_temp_versions
                local -a lc_temp_versions
                for lc_version in "${lc_operator_specified_versions[@]}"; do
                    local lc_match_found=0
                    for lc_match_ver in "${lc_matching_versions[@]}"; do
                        [[ "$lc_version" == "$lc_match_ver" ]] && lc_match_found=1 && break
                    done
                    [[ $lc_match_found -eq 0 ]] && lc_temp_versions+=("$lc_version")
                done
                unset lc_operator_specified_versions
                [[ ${#lc_temp_versions[@]} -gt 0 ]] && declare -a lc_operator_specified_versions=("${lc_temp_versions[@]}") || declare -a lc_operator_specified_versions
            fi
        else
            unset lc_matching_versions
        fi

        log_echo "---------------------------------"
        log "INFO" "Total Number of Channels: $(echo "$lc_channels" | wc -l)"
        log "INFO" "    Default Channel Name: $lc_default_channel"
        [[ ${#lc_identical_channels[@]} -eq 0 ]] && log "INFO" "Channels with Identical Version List to Default Channel : None" || log "INFO" "Channels with Identical Version List to Default Channel : ${!lc_identical_channels[@]}"
        log_echo "---------------------------------"
        [[ -z "${lc_matching_versions+x}" ]] && log "INFO" "Matching versions: None" || {
            log "INFO" "Matching versions:"
            log_echo "$(printf '            %s\n' "${lc_matching_versions[@]}")"
        }
        [[ ${#lc_operator_specified_versions[@]} -eq 0 ]] && log "INFO" "Remaining versions: None" || {
            log "INFO" "Remaining versions:"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        }

        cat <<EOF >> "$lc_imageset_config_file"
    - name: $lc_package_name
      channels:
EOF
        log "INFO" "***yaml*** defaultChannel: $lc_default_channel"
        cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_default_channel")
EOF
        if [[ -n "${lc_matching_versions+x}" && ${#lc_matching_versions[@]} -gt 0 ]]; then
            lc_is_min_version_added="true"
            local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions[@]}" | sort -V | head -n 1)
            log "INFO" "***yaml*** Add minVersion to defaultChannel($lc_default_channel): raw=$lc_min_matching_version, extracted=$(get_extract_version "$lc_min_matching_version")"
            cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
        fi

        local lc_highest_channel_different_channel lc_check_highest_default_channel
        if [[ ${#lc_different_channels[@]} -gt 0 ]]; then
            lc_highest_channel_different_channel=$(get_highest_channel "$(printf '%s\n' "${!lc_different_channels[@]}")" "$lc_catalog_file")
            lc_check_highest_default_channel=$(get_highest_channel "$lc_highest_channel_different_channel $lc_default_channel" "$lc_catalog_file")

            log_echo "---------------------------------"
            [[ ${#lc_different_channels[@]} -eq 0 ]] && log "INFO" "Additional Channels: None" || {
                log "INFO" "Additional Channels (${#lc_different_channels[@]}) :"
                log_echo "$(printf '            %s\n' "${!lc_different_channels[@]}" | sort -Vr)"
            }
            [[ "$lc_default_channel" == "$lc_check_highest_default_channel" ]] && log "INFO" "Is Default Channel the Highest? Yes ($lc_default_channel == $lc_check_highest_default_channel)" || log "INFO" "Is Default Channel the Highest? No ($lc_default_channel != $lc_check_highest_default_channel)"
            log_echo "---------------------------------"

            unset lc_added_channels
            local -A lc_added_channels

            if [[ "$lc_check_highest_default_channel" != "$lc_default_channel" ]]; then
                unset lc_matching_versions_highest
                mapfile -t lc_matching_versions_highest < <(get_matching_versions "$(get_versions_for_channel "$lc_highest_channel_different_channel" "$lc_catalog_file")" "${lc_operator_specified_versions[@]}")
                if [[ ${#lc_matching_versions_highest[@]} -gt 0 || ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                    if [[ ${#lc_matching_versions_highest[@]} -gt 0 ]]; then
                        lc_is_min_version_added="true"
                        unset lc_temp_versions
                        local -a lc_temp_versions
                        for lc_version in "${lc_operator_specified_versions[@]}"; do
                            local lc_match_found=0
                            for lc_match_ver in "${lc_matching_versions_highest[@]}"; do
                                [[ "$lc_version" == "$lc_match_ver" ]] && lc_match_found=1 && break
                            done
                            [[ $lc_match_found -eq 0 ]] && lc_temp_versions+=("$lc_version")
                        done
                        unset lc_operator_specified_versions
                        [[ ${#lc_temp_versions[@]} -gt 0 ]] && declare -a lc_operator_specified_versions=("${lc_temp_versions[@]}") || declare -a lc_operator_specified_versions
                    fi
                    log "INFO" "Channel: $lc_highest_channel_different_channel"
                    [[ ${#lc_matching_versions_highest[@]} -eq 0 ]] && log "INFO" "Matching versions : None" || {
                        log "INFO" "Matching versions:"
                        log_echo "$(printf '            %s\n' "${lc_matching_versions_highest[@]}")"
                    }
                    [[ ${#lc_operator_specified_versions[@]} -eq 0 ]] && log "INFO" "Remaining versions : None" || {
                        log "INFO" "Remaining versions :"
                        log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                    }
                    log "INFO" "***yaml*** Add Channel : $lc_highest_channel_different_channel"
                    cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_highest_channel_different_channel")
EOF
                    if [[ ${#lc_matching_versions_highest[@]} -gt 0 ]]; then
                        local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions_highest[@]}" | sort -V | head -n 1)
                        log "INFO" "***yaml*** Add minVersion to Channel($lc_highest_channel_different_channel): raw=$lc_min_matching_version, extracted=$(get_extract_version "$lc_min_matching_version")"
                        cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
                    fi
                    lc_added_channels["$lc_highest_channel_different_channel"]=1
                    lc_is_highest_channel_added="true"
                fi
            fi

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
                                    [[ "$lc_version" == "$lc_match_ver" ]] && lc_match_found=1 && break
                                done
                                [[ $lc_match_found -eq 0 ]] && lc_temp_versions+=("$lc_version")
                            done
                            unset lc_operator_specified_versions
                            [[ ${#lc_temp_versions[@]} -gt 0 ]] && declare -a lc_operator_specified_versions=("${lc_temp_versions[@]}") || declare -a lc_operator_specified_versions
                            [[ ${#lc_operator_specified_versions[@]} -eq 0 ]] && log "INFO" "Remaining versions : None" || {
                                log "INFO" "Remaining versions :"
                                log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                            }
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

            ### Add highest channel if no versions specified and no minVersion/highest channel added
            if [[ ${#lc_operator_specified_versions[@]} -eq 0 && "$lc_is_min_version_added" == "false" && "$lc_is_highest_channel_added" == "false" ]]; then
                log "INFO" "***yaml*** Add Channel: $lc_highest_channel_different_channel"
                cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_highest_channel_different_channel")
EOF
                lc_added_channels["$lc_highest_channel_different_channel"]=1
                lc_is_highest_channel_added="true"
            fi
        else
            ### Log remaining versions if no different channels exist
            if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
                log "WARN" "Specified versions not found in catalog for operator '$lc_package_name' in OCP $OCP_VERSIONS (only default channel '$lc_default_channel' available)."
                log "WARN" "Remaining versions:"
                log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                log "WARN" "Please verify the version specifications in REDHAT_OPERATORS or check compatibility with OCP $OCP_VERSIONS."
                log_echo ""
            fi
        fi
        log "INFO" "[$(date +'%Y-%m-%d %H:%M:%S')] Completed processing package: $lc_package"
        log_echo ""
        ((lc_processed_packages++))
    done

    [[ $lc_processed_packages -eq 0 ]] && {
        log "ERROR" "No packages were processed successfully in set_contents(). Check catalog data in $lc_catalog_source_dir. Exiting..."
        exit 1
    }

    log "INFO" "[$(date +'%Y-%m-%d %H:%M:%S')] Completed set_contents() with $lc_processed_packages packages processed"
}

### Main Logic
log "INFO" "Starting script with OCP_VERSIONS: $OCP_VERSIONS"
extract_ocp_versions
log "INFO" "After extract_ocp_versions, MAJOR_MINOR_ARRAY: ${MAJOR_MINOR_ARRAY[*]}"

[[ ${#MAJOR_MINOR_ARRAY[@]} -eq 0 ]] && {
    log "ERROR" "MAJOR_MINOR_ARRAY is empty after extract_ocp_versions. Exiting..."
    exit 1
}

unset catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"
log "INFO" "Catalogs: ${catalogs[*]}"
log "INFO" "MIRROR_STRATEGY: $MIRROR_STRATEGY"

[[ ${#catalogs[@]} -eq 0 ]] && {
    log "ERROR" "No catalogs found in OLM_CATALOGS. Exiting..."
    exit 1
}

if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    for catalog in "${catalogs[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/${catalog}/$MIRROR_STRATEGY"
        [[ -d "$oc_mirror_work_dir" ]] && {
            log "INFO" "Removing existing directory $oc_mirror_work_dir"
            chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
            rm -Rf "$oc_mirror_work_dir" || {
                log "ERROR" "Failed to remove $oc_mirror_work_dir. Exiting..."
                exit 1
            }
        }
        mkdir -p "$oc_mirror_work_dir" || {
            log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
            exit 1
        }
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        imageset_config_files+=("$imageset_config_file")

        cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
EOF
        for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
            catalog_source_dir="$WORK_DIR/oc-mirror/index/$catalog/$major_minor"
            catalog_index="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
            catalog_info_log="$log_dir/olm-catalog-channel-info-${catalog}-${major_minor}.log"

            cat << EOF >> "$imageset_config_file"
  - catalog: $catalog_index
    packages:
EOF
            pull_catalog_index "$catalog" "$catalog_source_dir" "$catalog_index" "$catalog_info_log"
            set_contents       "$catalog" "$catalog_source_dir" "$catalog_index" "$imageset_config_file"
        done
    done
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    for catalog in "${catalogs[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/oc-mirror/olm/${catalog}/$MIRROR_STRATEGY"
        [[ -d "$oc_mirror_work_dir" ]] && {
            log "INFO" "Removing existing directory $oc_mirror_work_dir"
            chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
            rm -Rf "$oc_mirror_work_dir" || {
                log "ERROR" "Failed to remove $oc_mirror_work_dir. Exiting..."
                exit 1
            }
        }
        mkdir -p "$oc_mirror_work_dir" || {
            log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
            exit 1
        }
        unset current_versions
        for ((i=0; i<${#MAJOR_MINOR_ARRAY[@]}; i++)); do
            current_versions=("${MAJOR_MINOR_ARRAY[@]:0:$((i+1))}")
            version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

            imageset_config_file="$oc_mirror_work_dir/imageset-config-$version_string.yaml"
            imageset_config_files+=("$imageset_config_file")

            cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
EOF
            for major_minor in "${current_versions[@]}"; do
                catalog_source_dir="$WORK_DIR/oc-mirror/index/$catalog/$major_minor"
                catalog_index="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
                catalog_info_log="$log_dir/olm-catalog-channel-info-${catalog}-${major_minor}.log"

                cat << EOF >> "$imageset_config_file"
  - catalog: $catalog_index
    packages:
EOF
                pull_catalog_index "$catalog" "$catalog_source_dir" "$catalog_index" "$catalog_info_log"
                set_contents "$catalog" "$catalog_source_dir" "$catalog_index" "$imageset_config_file"
            done
        done
    done
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    for catalog in "${catalogs[@]}"; do
        for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
            catalog_source_dir="$WORK_DIR/oc-mirror/index/$catalog/$major_minor"
            catalog_index="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
            catalog_info_log="$log_dir/olm-catalog-channel-info-${catalog}-${major_minor}.log"

            oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$MIRROR_STRATEGY/$major_minor"
            [[ -d "$oc_mirror_work_dir" ]] && {
                log "INFO" "Removing existing directory $oc_mirror_work_dir"
                chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir. Continuing..."
                rm -Rf "$oc_mirror_work_dir" || {
                    log "ERROR" "Failed to remove $oc_mirror_work_dir. Exiting..."
                    exit 1
                }
            }
            mkdir -p "$oc_mirror_work_dir" || {
                log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
                exit 1
            }
            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
            imageset_config_files+=("$imageset_config_file")

            cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: $catalog_index
    packages:
EOF
            pull_catalog_index "$catalog" "$catalog_source_dir" "$catalog_index" "$catalog_info_log"
            set_contents "$catalog" "$catalog_source_dir" "$catalog_index" "$imageset_config_file"
        done
    done
else
    log "ERROR" "Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'. Exiting..."
    exit 1
fi

### Log completion
log_echo ""
log "INFO" "ImageSet configuration generation completed."
log "INFO" "Log Files:"
for file in "$log_file" "${log_files[@]}"; do
    log "INFO" "  $file"
done
log "INFO" "Generated ImageSet Configuration Files:"
for file in "${imageset_config_files[@]}"; do
    log "INFO" "  $file"
done
log_echo ""