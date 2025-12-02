#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Operator ImageSet Configuration
### ---------------------------------------------------------------------------------
### This script generates ImageSetConfiguration manifests for mirroring specific
### OpenShift Operators by processing local catalog data pulled via Podman.

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

### Declare global arrays to store paths of generated files for the final summary.
declare -a log_files imageset_config_files
log_files=()
imageset_config_files=()

### Declare array to store skipped operator names
declare -a SKIPPED_OPERATORS
SKIPPED_OPERATORS=()

### Validate that the operator channel analysis sub-script exists.
operator_channel_info_sh="$(dirname "$(realpath "$0")")/oc-mirror-03-ocp4-operator-images-00-operator-channel-info.sh"
if [[ ! -f "$operator_channel_info_sh" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Operator channel info script '$operator_channel_info_sh' not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Functions for Catalog Processing and Configuration
### ---------------------------------------------------------------------------------
### Pulls an operator catalog index image using Podman and extracts its contents.
pull_catalog_index() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3"

    printf "%-8s%-80s\n" "[INFO]" "    -- Starting Catalog Pull"
    printf "%-8s%-80s\n" "[INFO]" "       PULL_OLM_INDEX_IMAGE: $PULL_OLM_INDEX_IMAGE"
    printf "%-8s%-80s\n" "[INFO]" "       Catalog Source Dir  : $lc_catalog_source_dir"
    printf "%-8s%-80s\n" "[INFO]" "       Catalog Index Image : $lc_catalog_index"

    ### Create the catalog source directory if it doesn't exist.
    if [[ ! -d "$lc_catalog_source_dir" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "       Creating catalog source directory: '$lc_catalog_source_dir'..."
        mkdir -p "$lc_catalog_source_dir" || {
            printf "%-8s%-80s\n" "[ERROR]" "       Failed to create directory '$lc_catalog_source_dir'. Exiting..."
            exit 1
        }
        chmod 755 "$lc_catalog_source_dir"
        if [[ "$PULL_OLM_INDEX_IMAGE" == "false" ]]; then
            PULL_OLM_INDEX_IMAGE="true"
            printf "%-8s%-80s\n" "[INFO]" "       Forcing PULL_OLM_INDEX_IMAGE to 'true' because the catalog directory was missing."
        fi
    fi

    ### Pull and extract the catalog index image if configured to do so.
    if [[ "$PULL_OLM_INDEX_IMAGE" == "true" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "       Removing existing local image '$lc_catalog_index' (if present) and clearing catalog directory..."
        podman rmi "$lc_catalog_index" 2>/dev/null || true
        rm -Rf "$lc_catalog_source_dir"/*

        printf "%-8s%-80s\n" "[INFO]" "       Pulling catalog data from image to '$lc_catalog_source_dir'..."
        podman run \
            --user "$(id -u):$(id -g)" \
            --authfile "$PULL_SECRET_FILE" \
            -i --rm \
            -v "$lc_catalog_source_dir:/mnt:z" \
            --entrypoint /bin/sh "$lc_catalog_index" \
            -c "cp -R /configs/* /mnt/" 2>&1
    else
        printf "%-8s%-80s\n" "[INFO]" "       Skipping catalog index pull as PULL_OLM_INDEX_IMAGE is false."
        printf "%-8s%-80s\n" "[INFO]" "       Using existing data in '$lc_catalog_source_dir'."
    fi
}

### Retrieves the default channel name from a catalog file.
get_defaultchannel_for_operator() {
    local lc_catalog_file="$1"
    if [[ ! -s "$lc_catalog_file" ]]; then return; fi
    jq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Retrieves all channel names from a catalog file.
get_channels_for_operator() {
    local lc_catalog_file="$1"
    if [[ ! -s "$lc_catalog_file" ]]; then return; fi
    jq -r 'select(.schema == "olm.channel") | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Retrieves all bundle versions for a specific channel from a catalog file.
get_versions_for_channel() {
    local lc_channel="$1" lc_catalog_file="$2"
    if [[ ! -s "$lc_catalog_file" ]]; then return; fi
    jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name // ""' "$lc_catalog_file" | sort -Vr -u 2>/dev/null || echo ""
}

### Retrieves the display version (e.g., 1.2.3) from a bundle's properties.
get_properties_version() {
    local lc_full_version="$1" lc_catalog_file="$2"
    if [[ ! -s "$lc_catalog_file" ]]; then return; fi
    jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""' "$lc_catalog_file" 2>/dev/null || echo ""
}

### Extracts a semantic version number from a bundle name (e.g., "package.v1.2.3" -> "1.2.3").
get_extract_version() {
    local lc_input="$1"
    if [[ -z "$lc_input" ]]; then return; fi
    # Try to extract standard semantic version (X.Y.Z)
    echo "$lc_input" | sed -E 's/^[a-zA-Z0-9_-]+\.v?//; s/^v//'
}

### Finds versions from a list that match a specified set of versions.
get_matching_versions() {
    local lc_versions="$1"
    shift
    local lc_specified_versions=("$@")
    local -A lc_matching_versions_map
    lc_matching_versions_map=()
    if [[ ${#lc_specified_versions[@]} -eq 0 ]]; then return; fi

    local lc_ver lc_spec_ver
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

### Formats a string for YAML output, adding quotes if it looks like a number.
get_string() {
    local lc_string="$1"
    if [[ "$lc_string" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "'$lc_string'"
    else
        echo "$lc_string"
    fi
}

### Creates a detailed log file with channel and version info for each operator.
create_catalog_info() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3" lc_catalog_info_log="$4"
    local -a lc_operators

    case "$lc_catalog" in
        "redhat")    lc_operators=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_operators=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_operators=("${COMMUNITY_OPERATORS[@]}");;
        *) printf "%-8s%-80s\n" "[ERROR]" "       Invalid catalog type '$lc_catalog'. Exiting..."; exit 1;;
    esac

    if [[ ${#lc_operators[@]} -eq 0 || -z "${lc_operators[0]}" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       No operators defined for the '$lc_catalog' catalog. Exiting..."
        exit 1
    fi

    printf "%-8s%-80s\n" "[INFO]" "       Generating detailed catalog info for ${#lc_operators[@]} operator(s) in '$lc_catalog' catalog..."
    printf "%-8s%-80s\n" "[INFO]" "       Output log file: $lc_catalog_info_log"

    echo "Catalog Analysis Log for $lc_catalog" > "$lc_catalog_info_log"

    for lc_package in "${lc_operators[@]}"; do
        if [[ -z "$lc_package" ]]; then continue; fi

        IFS='|' read -r -a lc_version_parts <<< "$lc_package"
        lc_package_name="${lc_version_parts[0]}"

        local lc_catalog_file=""
        for fname in catalog.json index.json channel.json channel-stable.json channels.json package.json bundles.json; do
            if [[ -f "$lc_catalog_source_dir/$lc_package_name/$fname" ]]; then
                lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/$fname"
                break
            fi
        done

        if [[ -z "$lc_catalog_file" ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       No catalog file found for operator '$lc_package_name'. Skipping info generation."
            SKIPPED_OPERATORS+=("$lc_package_name")
            continue
        fi

        echo "=======================================================================" >> "$lc_catalog_info_log" 2>&1
        echo "Catalog : $lc_catalog_index"                                             >> "$lc_catalog_info_log" 2>&1
        echo "Operator: $lc_package_name"                                              >> "$lc_catalog_info_log" 2>&1
        echo "=======================================================================" >> "$lc_catalog_info_log" 2>&1
        bash "$operator_channel_info_sh" "$lc_catalog_file"                            >> "$lc_catalog_info_log" 2>&1
        echo ""                                                                        >> "$lc_catalog_info_log" 2>&1

        printf "%-8s%-80s\n" "[INFO]" "       - Generated channel info for '$lc_package_name'"
    done
}

### Generates the 'packages' section of the imageset-config.yaml file.
set_contents() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3" lc_imageset_config_file="$4"
    local -a lc_operators lc_operator_specified_versions
    local lc_processed_packages=0
    local lc_package_name lc_default_channel

    case "$lc_catalog" in
        "redhat")    lc_operators=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_operators=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_operators=("${COMMUNITY_OPERATORS[@]}");;
        *) printf "%-8s%-80s\n" "[ERROR]" "       Invalid catalog type '$lc_catalog'. Exiting..."; exit 1;;
    esac

    for lc_package in "${lc_operators[@]}"; do
        lc_operator_specified_versions=()

        # [FIX] Declare these as Associative Arrays explicitly using -A to prevent 'unbound variable' error
        local -A lc_identical_channels
        local -A lc_different_channels
        lc_identical_channels=()
        lc_different_channels=()

        ### Split package entry into name and specifically requested versions.
        IFS='|' read -r -a lc_version_parts <<< "$lc_package"
        lc_package_name="${lc_version_parts[0]}"
        mapfile -t lc_operator_specified_versions < <(printf '%s\n' "${lc_version_parts[@]:1}" | sort -Vr)

        if [[ -v lc_operator_specified_versions && ${#lc_operator_specified_versions[@]} -eq 1 && -z "${lc_operator_specified_versions[0]}" ]]; then
            lc_operator_specified_versions=()
        fi

        local lc_catalog_file=""
        for fname in catalog.json index.json channel.json channel-stable.json channels.json package.json bundles.json; do
            if [[ -f "$lc_catalog_source_dir/$lc_package_name/$fname" ]]; then
                lc_catalog_file="$lc_catalog_source_dir/$lc_package_name/$fname"
                break
            fi
        done

        if [[ -z "$lc_catalog_file" ]]; then
            # Already logged in create_catalog_info
            continue
        fi

        printf "%-8s%-80s\n" "[INFO]" "    -- Processing Operator: $lc_package_name"

        ### CHECK: Warn if specified version doesn't look like a CSV name
        for ver in "${lc_operator_specified_versions[@]}"; do
            if [[ "$ver" != *"$lc_package_name"* ]]; then
                 printf "%-8s%-80s\n" "[WARN]" "       Possible Config Error: Specified version '$ver' does not contain package name."
                 printf "%-8s%-80s\n" "[WARN]" "       Please use full ClusterServiceVersion name (e.g., $lc_package_name.v1.2.3)."
            fi
        done

        lc_default_channel=$(get_defaultchannel_for_operator "$lc_catalog_file")
        if [[ -z "$lc_default_channel" ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       No default channel found for '$lc_package_name'. Skipping."
            continue
        fi

        local lc_default_versions
        lc_default_versions=$(get_versions_for_channel "$lc_default_channel" "$lc_catalog_file")
        local -a lc_channels_array
        mapfile -t lc_channels_array < <(get_channels_for_operator "$lc_catalog_file")

        # Categorize channels
        for lc_channel in "${lc_channels_array[@]}"; do
            if [[ "$lc_channel" != "$lc_default_channel" ]]; then
                if [[ "$lc_channel" == "candidate" ]]; then
                     printf "%-8s%-80s\n" "[INFO]" "       - Skipping channel 'candidate' by policy."
                     continue
                fi
                local lc_channel_versions
                lc_channel_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
                if [[ "$lc_channel_versions" == "$lc_default_versions" ]]; then
                    lc_identical_channels["$lc_channel"]=1
                else
                    lc_different_channels["$lc_channel"]=1
                fi
            fi
        done

        ### Process Default Channel
        local lc_matching_versions=()
        if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
            mapfile -t lc_matching_versions < <(get_matching_versions "$lc_default_versions" "${lc_operator_specified_versions[@]}")
            # Update remaining needed versions
            local lc_temp_versions=()
            for lc_version in "${lc_operator_specified_versions[@]}"; do
                local found=0
                for match in "${lc_matching_versions[@]}"; do
                    if [[ "$lc_version" == "$match" ]]; then found=1; break; fi
                done
                if [[ $found -eq 0 ]]; then lc_temp_versions+=("$lc_version"); fi
            done
            lc_operator_specified_versions=("${lc_temp_versions[@]}")
        fi

        ### Write YAML for Default Channel
        printf "%-8s%-80s\n" "[INFO]" "       Adding package: $lc_package_name (Default Channel: $lc_default_channel)"
        cat <<EOF >> "$lc_imageset_config_file"
    - name: $lc_package_name
      channels:
      - name: $(get_string "$lc_default_channel")
EOF
        if [[ ${#lc_matching_versions[@]} -gt 0 ]]; then
            local lc_min_ver
            lc_min_ver=$(printf '%s\n' "${lc_matching_versions[@]}" | sort -V | head -n 1)
            local extracted_ver
            extracted_ver=$(get_extract_version "$lc_min_ver")

            if [[ -n "$extracted_ver" ]]; then
                printf "%-8s%-80s\n" "[INFO]" "       minVersion: $extracted_ver (derived from $lc_min_ver)"
                cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$extracted_ver")
EOF
            else
                printf "%-8s%-80s\n" "[WARN]" "       Failed to extract version number from '$lc_min_ver'. Skipping minVersion."
            fi
        fi

        ### Process Other Channels (Fallback)
        if [[ ${#lc_different_channels[@]} -gt 0 && ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
             local -A lc_added_channels
             lc_added_channels=()

             for lc_channel in $(printf '%s\n' "${!lc_different_channels[@]}" | sort -Vr); do
                 local lc_channel_versions
                 lc_channel_versions=$(get_versions_for_channel "$lc_channel" "$lc_catalog_file")
                 local lc_matching_versions_channel=()
                 mapfile -t lc_matching_versions_channel < <(get_matching_versions "$lc_channel_versions" "${lc_operator_specified_versions[@]}")

                 if [[ ${#lc_matching_versions_channel[@]} -gt 0 ]]; then
                     # Filter remaining versions
                     local lc_temp_versions=()
                     for lc_version in "${lc_operator_specified_versions[@]}"; do
                         local found=0
                         for match in "${lc_matching_versions_channel[@]}"; do
                             if [[ "$lc_version" == "$match" ]]; then found=1; break; fi
                         done
                         if [[ $found -eq 0 ]]; then lc_temp_versions+=("$lc_version"); fi
                     done
                     lc_operator_specified_versions=("${lc_temp_versions[@]}")

                     printf "%-8s%-80s\n" "[INFO]" "       Found requested version in alternate channel: $lc_channel"
                     cat <<EOF >> "$lc_imageset_config_file"
      - name: $(get_string "$lc_channel")
EOF
                     local lc_min_ver
                     lc_min_ver=$(printf '%s\n' "${lc_matching_versions_channel[@]}" | sort -V | head -n 1)
                     local extracted_ver
                     extracted_ver=$(get_extract_version "$lc_min_ver")

                     if [[ -n "$extracted_ver" ]]; then
                         cat <<EOF >> "$lc_imageset_config_file"
        minVersion: $(get_string "$extracted_ver")
EOF
                     fi
                     lc_added_channels["$lc_channel"]=1
                 fi
             done
        fi

        ### Log Missing Versions
        if [[ ${#lc_operator_specified_versions[@]} -gt 0 ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       Could not find the following versions in ANY available channel:"
            for version in "${lc_operator_specified_versions[@]}"; do
                printf "%-8s%-80s\n" "[WARN]" "       - $version"
            done
        fi
        ((lc_processed_packages++)) || true
    done

    if [[ $lc_processed_packages -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       No packages were processed successfully for catalog '$lc_catalog'. Exiting..."
        exit 1
    fi
}

### ---------------------------------------------------------------------------------
### Main Execution
### ---------------------------------------------------------------------------------
if [[ ${#MAJOR_MINOR_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    MAJOR_MINOR_ARRAY is empty after version extraction. Exiting..."
    exit 1
fi

declare -a catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

if [[ ${#catalogs[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No catalogs found in OLM_CATALOGS variable. Exiting..."
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "=== Starting Operator ImageSet Configuration Generation ==="
printf "%-8s%-80s\n" "[INFO]" "--- Found ${#catalogs[@]} catalog(s) to process: ${catalogs[*]}"

### Iterate through each specified catalog and OCP version.
for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        catalog_source_dir="$WORK_DIR/oc-mirror/index/$catalog/$major_minor"
        catalog_index="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
        catalog_info_log="$log_dir/olm-${catalog}-catalog-channel-info-${major_minor}.log"
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        imageset_config_files+=("$imageset_config_file")
        log_files+=("$catalog_info_log")

        printf "%-8s%-80s\n" "[INFO]" "--- Processing Catalog: $catalog | OCP Version: $major_minor"
        printf "%-8s%-80s\n" "[INFO]" "    -- Preparing working directory '$oc_mirror_work_dir'..."
        if [[ -d "$oc_mirror_work_dir" ]]; then
            chmod -R u+w "$oc_mirror_work_dir" 2>/dev/null || printf "%-8s%-80s\n" "[WARN]" "       Failed to set write permissions on '$oc_mirror_work_dir'."
            rm -Rf "$oc_mirror_work_dir" || {
                printf "%-8s%-80s\n" "[ERROR]" "       Failed to remove '$oc_mirror_work_dir'. Check permissions. Exiting..."
                exit 1
            }
        fi
        mkdir -p "$oc_mirror_work_dir" || {
            printf "%-8s%-80s\n" "[ERROR]" "       Failed to create directory '$oc_mirror_work_dir'. Exiting..."
            exit 1
        }

        pull_catalog_index  "$catalog" "$catalog_source_dir" "$catalog_index"
        create_catalog_info "$catalog" "$catalog_source_dir" "$catalog_index" "$catalog_info_log"

        ### Initialize the ImageSetConfiguration file for the current catalog.
        printf "%-8s%-80s\n" "[INFO]" "    -- Creating initial ImageSetConfiguration file: '$imageset_config_file'..."
        cat << EOF > "$imageset_config_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: $catalog_index
    packages:
EOF
        ### Populate the 'packages' section based on the catalog analysis.
        set_contents "$catalog" "$catalog_source_dir" "$catalog_index" "$imageset_config_file"
    done
done

### Provide a final summary of all generated files.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Operator ImageSet Configuration Generation Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Summary of generated files:"
for file in "${log_files[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    - Operator Log   : $file"
done
for file in "${imageset_config_files[@]}"; do
    printf "%-8s%-80s\n" "[INFO]" "    - ImageSet Config: $file"
done

### MANUAL INTERVENTION WARNING
if [[ ${#SKIPPED_OPERATORS[@]} -gt 0 ]]; then
    echo ""
    printf "%-8s%-80s\n" "[!!WARN!!]" "=== MANUAL ACTION REQUIRED ==="
    printf "%-8s%-80s\n" "[!!WARN!!]" "    The following operators were SKIPPED because their catalog data was not found."
    printf "%-8s%-80s\n" "[!!WARN!!]" "    They were NOT added to the config file."

    mapfile -t unique_skipped < <(printf '%s\n' "${SKIPPED_OPERATORS[@]}" | sort -u)
    for operator in "${unique_skipped[@]}"; do
        printf "%-8s%-80s\n" "[!!WARN!!]" "    - $operator"
    done
    printf "%-8s%-80s\n" "[!!WARN!!]" "    Please verify spelling or check if they exist in this OCP version."
fi
echo ""