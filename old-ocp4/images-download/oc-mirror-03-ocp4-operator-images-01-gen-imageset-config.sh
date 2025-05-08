#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

### Declare global arrays for log files and imageset-config files
unset log_files_operator_info
declare -a log_files_operator_info
unset imageset_config_files
declare -a imageset_config_files

### Define logging functions
log_operator_info() {
    local lc_level="$1" lc_msg="$2" lc_log_file_operator_info="$3"
    printf "%-7s %s\n" "[$lc_level]" "$lc_msg" >> "$lc_log_file_operator_info"
}
log_echo_operator_info() {
    local lc_msg="$1" lc_flag="$2" lc_log_file_operator_info="$3"
    if [[ "$lc_flag" == "new" ]]; then
        echo "$lc_msg" > "$lc_log_file_operator_info"
    else
        echo "$lc_msg" >> "$lc_log_file_operator_info"
    fi
}

### Validate existence of operator channel info script
operator_channel_info_sh="$(dirname "$(realpath "$0")")/oc-mirror-03-ocp4-operator-images-00-operator-channel-info.sh"
if [[ ! -f "$operator_channel_info_sh" ]]; then
    log "ERROR" "Cannot access 'operator_channel_info_sh' at $operator_channel_info_sh. File or directory does not exist. Exiting..."
    exit 1
fi

### Initialize environment based on catalog type
initializing_environment() {
    local lc_catalog="$1"
    case "$lc_catalog" in
        "redhat")
            get_package_entries "$lc_catalog" "REDHAT_OPERATORS"
            ;;
        "certified")
            get_package_entries "$lc_catalog" "CERTIFIED_OPERATORS"
            ;;
        "community")
            get_package_entries "$lc_catalog" "COMMUNITY_OPERATORS"
            ;;
        *)
            log "ERROR" "Invalid catalog type '$lc_catalog'."
            exit 1
            ;;
    esac
}

### Extract package entries from operator variable
get_package_entries() {
    local lc_catalog="$1"
    local lc_operators_var="$2"
    local lc_operators="${!lc_operators_var}"

    if [[ -z "$lc_operators" ]]; then
        log "ERROR" "No operators defined for $lc_catalog catalog in $lc_operators_var. Exiting..."
        exit 1
    fi

    unset package_entries
    IFS='#' read -r -a package_entries <<< "$(echo "$lc_operators" | sed 's/::/#/g')"
}

### Pull and process catalog index
pull_catalog_index() {
    local lc_catalog="$1"
    local lc_major_minor="$2"
    log_file_operator_info="$log_dir/olm-catalog-channel-info-${lc_catalog}-${lc_major_minor}.log"

    catalog_source_dir="$WORK_DIR/oc-mirror/index/$lc_catalog/$lc_major_minor"
    catalog_index="registry.redhat.io/redhat/${lc_catalog}-operator-index:v${lc_major_minor}"

    local lc_exists=0
    for existing_file in "${log_files_operator_info[@]}"; do
        if [[ "$existing_file" == "$log_file_operator_info" ]]; then
            lc_exists=1
            break
        fi
    done
    if [[ $lc_exists -eq 0 ]]; then
        log_files_operator_info+=("$log_file_operator_info")
    fi

    log_echo "------------------------------"
    log      "INFO" "pull_catalog_index()"
    log_echo "------------------------------"
    log      "INFO" "     MIRROR_STRATEGY : $MIRROR_STRATEGY"
    log      "INFO" "PULL_OLM_INDEX_IMAGE : $PULL_OLM_INDEX_IMAGE"
    log      "INFO" "  catalog_source_dir : $catalog_source_dir"
    log      "INFO" "       Catalog Index : $catalog_index"
    log      "INFO" "            Log File : "
    log      "INFO" "                       $log_file"
    log      "INFO" "                       $log_file_operator_info"
    log_echo "------------------------------"

    if [[ ! -d "$catalog_source_dir" ]]; then
        PULL_OLM_INDEX_IMAGE="true"
        mkdir -p "$catalog_source_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to create directory $catalog_source_dir. Exiting..."
            exit 1
        fi
        chmod 777 "$catalog_source_dir"
    fi
    if [[ "$PULL_OLM_INDEX_IMAGE" == "true" ]]; then
        podman rmi "$catalog_index" 2>/dev/null
        
        rm -Rf "$catalog_source_dir"/*
        
        log_echo ""
        log "INFO" "Copying catalog data to '$catalog_source_dir'"
        log_echo ""

        podman run \
            --authfile "$PULL_SECRET_FILE" \
            -i --rm \
            -v "$catalog_source_dir:/mnt:z" \
            --entrypoint /bin/sh "$catalog_index" \
            -c "cp -R /configs/* /mnt/" | tee -a "$log_file"

        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to pull catalog index image $catalog_index. Check $log_file for details. Exiting..."
            exit 1
        fi

        if [[ -d "$catalog_source_dir" ]]; then
            local lc_packages=""
            log_echo_operator_info "[INFO] [$(date +"%Y-%m-%d %H:%M:%S")] " "new" "$log_file_operator_info"
            lc_packages=$(ls -1 "$catalog_source_dir" | tee -a "$log_file_operator_info")
            log_echo_operator_info "" "" "$log_file_operator_info"

            for lc_package_name in $lc_packages; do
                log_echo_operator_info "=======================================================================" "" "$log_file_operator_info"
                log_operator_info      "INFO" "Catalog : $catalog_index"                                            "$log_file_operator_info"
                log_operator_info      "INFO" "Operator: $lc_package_name"                                          "$log_file_operator_info"
                log_echo_operator_info "=======================================================================" "" "$log_file_operator_info"

                local lc_catalog_file="$catalog_source_dir/$lc_package_name/catalog.json"
                if [[ ! -f "$lc_catalog_file" ]]; then
                    lc_catalog_file="$catalog_source_dir/$lc_package_name/index.json"
                    if [[ ! -f "$lc_catalog_file" ]]; then
                        continue
                    fi
                fi
                bash "$operator_channel_info_sh" "$lc_catalog_file" >> "$log_file_operator_info"
                log_echo_operator_info "" "" "$log_file_operator_info"
            done
        fi
    fi
    log_echo ""
    log "INFO" "Operators available in catalog '$catalog_index'"
    log_echo ""
}

### Get default channel for an operator from catalog file
get_defaultchannel_for_operator() {
    local lc_catalog_file="$1"
    local lc_channel
    lc_channel=$(cat "$lc_catalog_file" | jq -r 'select(.schema == "olm.package") | .defaultChannel // ""')
    echo "$lc_channel"
}

### Get all channels for an operator from catalog file
get_channels_for_operator() {
    local lc_catalog_file="$1"
    local lc_channels
    lc_channels=$(cat "$lc_catalog_file" | jq -r 'select(.schema == "olm.channel") | .name // ""' | sort -Vr -u)
    echo "$lc_channels"
}

### Get versions available in a specific channel
get_versions_for_channel() {
    local lc_channel="$1"
    local lc_catalog_file="$2"
    local lc_versions
    lc_versions=$(cat "$lc_catalog_file" | jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' | sort -Vr -u)
    echo "$lc_versions"
}

### Get the highest version in a channel
get_maxversion_of_channel() {
    local lc_channel="$1"
    local lc_catalog_file="$2"
    local lc_max_version
    lc_max_version=$(cat "$lc_catalog_file" | jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' | sort -Vr | head -n 1)
    echo "$lc_max_version"
}

### Get version from bundle properties
get_properties_version() {
    local lc_full_version="$1"
    local lc_catalog_file="$2"
    local lc_prop_version
    lc_prop_version=$(cat "$lc_catalog_file" | jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""')
    echo "$lc_prop_version"
}

### Extract version number from full version string
get_extract_version() {
    local lc_input="$1"
    local lc_version="${lc_input#*.}"
    echo "${lc_version#v}"
}

### Find matching versions between channel versions and specified versions (수정됨)
get_matching_versions() {
    local lc_versions="$1"
    shift
    local lc_specified_versions=("$@")
    unset lc_matching_versions_map
    local -A lc_matching_versions_map
    unset lc_matching_versions
    local lc_matching_versions

    if [[ ${#lc_specified_versions[@]} -eq 0 ]]; then
        return
    fi

    for lc_ver in $lc_versions; do
        for lc_spec_ver in "${lc_specified_versions[@]}"; do
            if [[ "$lc_spec_ver" == "$lc_ver" ]]; then
                lc_matching_versions_map["$lc_spec_ver"]=1
            fi
        done
    done
    if [[ ${#lc_matching_versions_map[@]} -gt 0 ]]; then
        unset lc_matching_versions
        mapfile -t lc_matching_versions < <(printf '%s\n' "${!lc_matching_versions_map[@]}" | sort -V)
        printf '%s\n' "${lc_matching_versions[@]}"  # 개행 문자로 출력
    fi
}

### Determine the highest channel based on version
get_highest_channel() {
    local lc_channels="$1"
    local lc_catalog_file="$2"
    local lc_max_version=""
    local lc_max_channel=""
    local lc_versions=""
    local lc_extract_ver=""

    while IFS=$'\n' read -r lc_channel; do
        if [[ -n "$lc_channel" ]]; then
            lc_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
            for lc_ver in $lc_versions; do
                if [[ -n "$lc_ver" ]]; then
                    lc_extract_ver="$(get_extract_version "$lc_ver")"
                    if [[ -z "$lc_max_version" || "$(printf '%s\n%s' "$lc_extract_ver" "$lc_max_version" | sort -Vr | head -n 1)" == "$lc_extract_ver" ]]; then
                        lc_max_version="$lc_extract_ver"
                        lc_max_channel="$lc_channel"
                    fi
                fi
            done
        fi
    done <<< "$(echo "$lc_channels" | tr ' ' '\n' | sort -Vr)"

    echo "$lc_max_channel"
}

### Format string for YAML output (quote numeric strings)
get_string() {
    local lc_string="$1"
    if [[ "$lc_string" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "'$lc_string'"
    else
        echo "$lc_string"
    fi
}

### Generate content for imageset-config.yaml (수정됨)
set_contents() {
    local lc_package_name=""
    local lc_default_channel=""
    local lc_default_versions=""
    local lc_channels=""
    local lc_channel_versions=""
    local lc_match_found=0
    local lc_is_min_version_added="false"

    for lc_package in "${package_entries[@]}"; do
        if [[ -z "$lc_package" ]]; then
            continue
        fi
        IFS='|' read -r -a lc_version_parts <<< "$lc_package"

        lc_package_name="${lc_version_parts[0]}"
        unset lc_operator_specified_versions
        IFS=$'\n' lc_operator_specified_versions=($(sort -Vr <<<"${lc_version_parts[@]:1}"))

        local lc_catalog_file="$catalog_source_dir/$lc_package_name/catalog.json"
        if [[ ! -f "$lc_catalog_file" ]]; then
            lc_catalog_file="$catalog_source_dir/$lc_package_name/index.json"
            if [[ ! -f "$lc_catalog_file" ]]; then
                log "WARN" "No catalog file found for operator '$lc_package_name' at $lc_catalog_file. Skipping..."
                continue
            fi
        fi

        log_echo "======================================================================="
        log      "INFO" "Catalog : $catalog_index"
        log      "INFO" "Operator: $lc_package_name"
        if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
            log  "INFO" "Specified Versions : None"
        else
            log      "INFO" "Specified Versions :"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        fi
        log_echo "======================================================================="
        log_echo ""

        lc_default_channel=$(get_defaultchannel_for_operator "$lc_catalog_file")
        if [[ -z "$lc_default_channel" ]]; then
            log "WARN" "No default channel found for $lc_package_name in $lc_catalog_file. Skipping..."
            continue
        fi
        lc_default_versions=$(get_versions_for_channel "$lc_default_channel" "$lc_catalog_file")
        lc_channels=$(get_channels_for_operator "$lc_catalog_file")

        unset lc_identical_channels lc_different_channels
        local -A lc_identical_channels lc_different_channels

        while IFS=$'\n' read -r lc_channel; do
            if [[ "$lc_channel" != "$lc_default_channel" ]]; then
                lc_channel_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
                if [[ "$lc_channel_versions" == "$lc_default_versions" ]]; then
                    lc_identical_channels["$lc_channel"]=1
                else
                    if [[ "$lc_channel" != "candidate" ]]; then
                        lc_different_channels["$lc_channel"]=1
                    fi
                fi
            fi
        done <<< "$lc_channels"

        ### Matching Versions for Default Channel
        if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
            unset lc_matching_versions
            mapfile -t lc_matching_versions < <(get_matching_versions "$lc_default_versions" "${lc_operator_specified_versions[@]}")

            if [[ ${#lc_matching_versions[@]} -gt 0 ]]; then
                unset lc_temp_versions
                local -a lc_temp_versions
                for lc_version in "${lc_operator_specified_versions[@]}"; do
                    lc_match_found=0
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
        else
            unset lc_matching_versions
        fi

        log_echo "---------------------------------"
        log      "INFO" "Total Number of Channels: $(echo "$lc_channels" | wc -l)"
        log      "INFO" "    Default Channel Name: $lc_default_channel"
        if [[ ${#lc_identical_channels[@]} -eq 0 ]]; then
            log  "INFO" "Channels with Identical Version List to Default Channel : None"
        else
            log  "INFO" "Channels with Identical Version List to Default Channel : ${!lc_identical_channels[@]}"
        fi
        log_echo "---------------------------------"
        log_echo ""
        if [[ -z "${lc_matching_versions+x}" ]]; then
            log  "INFO" "Matching  versions: None"
        else
            log  "INFO" "Matching  versions:"
            log_echo "$(printf '            %s\n' "${lc_matching_versions[@]}")"
        fi
        if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
            log  "INFO" "Remaining versions: None"
        else
            log  "INFO" "Remaining versions:"
            log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
        fi
        log_echo ""

        cat <<EOF >> "$imageset_config_file"
    - name: $lc_package_name
      channels:
EOF
        log "INFO" "***yaml***"
        log "INFO" "***yaml*** defaultChannel: $lc_default_channel"
        log "INFO" "***yaml***"
        log_echo ""
        cat <<EOF >> "$imageset_config_file"
      - name: $(get_string "$lc_default_channel")
EOF
        if [[ -n "${lc_matching_versions+x}" && ${#lc_matching_versions[@]} -gt 0 ]]; then
            lc_is_min_version_added="true"
            local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions[@]}" | sort -V | head -n 1)

            log "INFO" "***yaml***"
            log "INFO" "***yaml*** Add minVersion to defaultChannel($lc_default_channel): $lc_min_matching_version"
            log "INFO" "***yaml***"
            log_echo ""
            cat <<EOF >> "$imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
        fi

        local lc_highest_channel_different_channel
        local lc_check_highest_default_channel
        if [[ ${#lc_different_channels[@]} -gt 0 ]]; then
            lc_highest_channel_different_channel=$(get_highest_channel "$(printf '%s\n' "${!lc_different_channels[@]}")" "$lc_catalog_file")
            lc_check_highest_default_channel=$(get_highest_channel "$lc_highest_channel_different_channel $lc_default_channel" "$lc_catalog_file")

            log_echo     "---------------------------------"
            if [[ ${#lc_different_channels[@]} -eq 0 ]]; then
                log      "INFO" "Additional Channels: None"
            else
                log      "INFO" "Additional Channels (${#lc_different_channels[@]}) :"
                log_echo "$(printf '            %s\n' "${!lc_different_channels[@]}" | sort -Vr)"
            fi
            if [[ "$lc_default_channel" == "$lc_check_highest_default_channel" ]]; then
                log      "INFO" "Is Default Channel the Highest? Yes ($lc_default_channel == $lc_check_highest_default_channel)"
            else
                log      "INFO" "Is Default Channel the Highest? No ($lc_default_channel != $lc_check_highest_default_channel)"
            fi
            log_echo     "---------------------------------"
            log_echo     ""

            unset lc_added_channels
            local -A lc_added_channels
            local lc_is_highest_channel_added="false"

            if [[ "$lc_check_highest_default_channel" != "$lc_default_channel" ]]; then
                unset lc_matching_versions_highest
                mapfile -t lc_matching_versions_highest < <(get_matching_versions "$(get_versions_for_channel "$lc_highest_channel_different_channel" "$lc_catalog_file")" "${lc_operator_specified_versions[@]}")
                if [[ ${#lc_matching_versions_highest[@]} -gt 0 || ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                    if [[ ${#lc_matching_versions_highest[@]} -gt 0 ]]; then
                        lc_is_min_version_added="true"
                        unset lc_temp_versions
                        local -a lc_temp_versions
                        for lc_version in "${lc_operator_specified_versions[@]}"; do
                            lc_match_found=0
                            for lc_match_ver in "${lc_matching_versions_highest[@]}"; do
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
                    log "INFO" "Channel: $lc_highest_channel_different_channel"
                    if [[ ${#lc_matching_versions_highest[@]} -eq 0 ]]; then
                        log "INFO" "Matching  versions : None"
                    else
                        log  "INFO" "Matching  versions:"
                        log_echo "$(printf '            %s\n' "${lc_matching_versions_highest[@]}")"
                    fi

                    if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                        log "INFO" "Remaining versions : None"
                    else
                        log "INFO" "Remaining versions :"
                        printf '            %s\n' "${lc_operator_specified_versions[@]}" | tee -a "$log_file"
                    fi
                    log_echo ""
                    log "INFO" "***yaml***"
                    log "INFO" "***yaml*** Add Channel : $lc_highest_channel_different_channel"
                    log "INFO" "***yaml***"
                    log_echo ""
                    cat <<EOF >> "$imageset_config_file"
      - name: $(get_string "$lc_highest_channel_different_channel")
EOF
                    if [[ ${#lc_matching_versions_highest[@]} -gt 0 ]]; then
                        local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions_highest[@]}" | sort -V | head -n 1)
                        log "INFO" "***yaml***"
                        log "INFO" "***yaml*** Add minVersion to Channel($lc_highest_channel_different_channel) : $lc_min_matching_version"
                        log "INFO" "***yaml***"
                        log_echo ""
                        cat <<EOF >> "$imageset_config_file"
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
                            log  "INFO" "Matching  versions:"
                            log_echo "$(printf '            %s\n' "${lc_matching_versions_channel[@]}")"
                            unset lc_temp_versions
                            local -a lc_temp_versions
                            for lc_version in "${lc_operator_specified_versions[@]}"; do
                                lc_match_found=0
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
                                log      "INFO" "Remaining versions : None"
                            else
                                log      "INFO" "Remaining versions :"
                                log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                            fi
                            log_echo ""
                            log "INFO" "***yaml***"
                            log "INFO" "***yaml*** Add Channel: $(get_string "$lc_channel")"
                            log "INFO" "***yaml***"
                            log_echo ""
                            cat <<EOF >> "$imageset_config_file"
      - name: $(get_string "$lc_channel")
EOF
                            local lc_min_matching_version=$(printf '%s\n' "${lc_matching_versions_channel[@]}" | sort -V | head -n 1)
                            log "INFO" "***yaml***"
                            log "INFO" "***yaml*** Add minVersion to Channel($lc_channel): $lc_min_matching_version"
                            log "INFO" "***yaml***"
                            log_echo ""
                            cat <<EOF >> "$imageset_config_file"
        minVersion: $(get_string "$(get_extract_version "$lc_min_matching_version")")
EOF
                            lc_added_channels["$lc_channel"]=1
                        fi
                    fi
                done
            fi

            if [[ ${#lc_operator_specified_versions[@]} -eq 0 && "$lc_is_min_version_added" == "false" && "$lc_is_highest_channel_added" == "false" ]]; then
                log "INFO" "***yaml***"
                log "INFO" "***yaml*** Add Channel: $lc_highest_channel_different_channel"
                log "INFO" "***yaml***"
                log_echo ""
                cat <<EOF >> "$imageset_config_file"
      - name: $(get_string "$lc_highest_channel_different_channel")
EOF
                lc_added_channels["$lc_highest_channel_different_channel"]=1
                lc_is_highest_channel_added="true"
            fi

            if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
                if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                    log      "INFO" "Remaining versions : None"
                else
                    log      "WARN" "No versions found for this operator in any channel."
                    log      "WARN" "Remaining versions :"
                    log_echo "$(printf '            %s\n' "${lc_operator_specified_versions[@]}")"
                fi
                log_echo ""
            fi
        else
            if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
                if [[ ${#lc_operator_specified_versions[@]} -eq 0 ]]; then
                    log "INFO" "Remaining versions : None"
                else
                    log "WARN" "No versions found for this operator in any channel."
                    log "WARN" "Remaining versions :"
                    printf '            %s\n' "${lc_operator_specified_versions[@]}" | tee -a "$log_file"
                fi
                log_echo ""
            fi
        fi
    done
}

###
### Main Logic: Process catalogs and versions based on mirror strategy
###

extract_ocp_versions

unset catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    for catalog in "${catalogs[@]}"; do
        initializing_environment "$catalog"
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/${catalog}/$MIRROR_STRATEGY"
        if [[ -d "$oc_mirror_work_dir" ]]; then
            rm -Rf "$oc_mirror_work_dir"
        fi
        mkdir -p "$oc_mirror_work_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
            exit 1
        fi
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        imageset_config_files+=("$imageset_config_file")

        cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
EOF
        for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
            pull_catalog_index "$catalog" "$major_minor"
            cat << EOF >> "$imageset_config_file"
  - catalog: $catalog_index
    packages:
EOF
            set_contents
        done
        log "INFO" "Generated $imageset_config_file"
    done
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    for catalog in "${catalogs[@]}"; do
        initializing_environment "$catalog"
        oc_mirror_work_dir="$WORK_DIR/oc-mirror/olm/${catalog}/$MIRROR_STRATEGY"
        if [[ -d "$oc_mirror_work_dir" ]]; then
            rm -Rf "$oc_mirror_work_dir"
        fi
        mkdir -p "$oc_mirror_work_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
            exit 1
        fi
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
                pull_catalog_index "$catalog" "$major_minor"
                cat << EOF >> "$imageset_config_file"
  - catalog: $catalog_index
    packages:
EOF
                set_contents
            done
            log "INFO" "Generated $imageset_config_file"
        done
    done
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    for catalog in "${catalogs[@]}"; do
        initializing_environment "$catalog"
        for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
            oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$MIRROR_STRATEGY/$major_minor"
            if [[ ! -d "$oc_mirror_work_dir" ]]; then
                mkdir -p "$oc_mirror_work_dir"
                if [[ $? -ne 0 ]]; then
                    log "ERROR" "Failed to create directory $oc_mirror_work_dir. Exiting..."
                    exit 1
                fi
            fi
            if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
                rm -Rf "$oc_mirror_work_dir/working-dir"
            fi
            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
            imageset_config_files+=("$imageset_config_file")
            
            cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
EOF
            pull_catalog_index "$catalog" "$major_minor"
            cat << EOF >> "$imageset_config_file"
  - catalog: $catalog_index
    packages:
EOF
            set_contents
        done
    done
else
    log "ERROR" "Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'. Exiting..."
    exit 1
fi

log_echo ""
log      "INFO" "ImageSet configuration generation completed."
log      "INFO" "Log Files:"
for file in "$log_file" "${log_files_operator_info[@]}"; do
    log  "INFO" "  $file"
done
log      "INFO" "Generated ImageSet Configuration Files:"
for file in "${imageset_config_files[@]}"; do
    log  "INFO" "  $file"
done