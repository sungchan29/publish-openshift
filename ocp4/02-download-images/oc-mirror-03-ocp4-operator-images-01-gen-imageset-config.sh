#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Operator ImageSet Configuration
### ---------------------------------------------------------------------------------
### This script generates ImageSetConfiguration manifests for mirroring specific
### OpenShift Operators by processing local catalog data pulled via Podman.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### 1. Load Configuration
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Loading Configuration ==="

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="${SCRIPT_DIR}/oc-mirror-00-config-setup.sh"

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

if [[ -z "${WORK_DIR:-}" || -z "${PULL_SECRET_FILE:-}" || -z "${log_dir:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, PULL_SECRET_FILE, log_dir) are not set." >&2
    exit 1
fi

if ! command -v podman >/dev/null; then
    printf "%-8s%-80s\n" "[ERROR]" "    'podman' command is required but not installed." >&2
    exit 1
fi

### Check for yq
if ! command -v ./yq >/dev/null; then
    printf "%-8s%-80s\n" "[WARN]" "    'yq' command not found. Processing 'catalog.yaml' will fail if encountered."
fi

### Extract OCP versions
extract_ocp_versions
if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No valid OCP versions found." >&2
    exit 1
fi

### Check for helper script
operator_channel_info_sh="${SCRIPT_DIR}/oc-mirror-03-ocp4-operator-images-00-operator-channel-info.sh"
if [[ ! -f "$operator_channel_info_sh" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Helper script '$operator_channel_info_sh' not found." >&2
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### Global Arrays
declare -a log_files imageset_config_files
declare -a SKIPPED_OPERATORS=()

### ---------------------------------------------------------------------------------
### 3. Catalog Processing Functions
### ---------------------------------------------------------------------------------

### Pulls an operator catalog index image using Podman
pull_catalog_index() {
    local lc_catalog="$1" lc_catalog_source_dir="$2" lc_catalog_index="$3"

    printf "%-8s%-80s\n" "[INFO]" "    -- Pulling Catalog Index"
    printf "%-8s%-80s\n" "[INFO]" "       Index Image : $lc_catalog_index"

    ### Prepare Directory
    if [[ ! -d "$lc_catalog_source_dir" ]]; then
        mkdir -p "$lc_catalog_source_dir"
        chmod 755 "$lc_catalog_source_dir"
        if [[ "${PULL_OLM_INDEX_IMAGE:-true}" == "false" ]]; then
            PULL_OLM_INDEX_IMAGE="true"
            printf "%-8s%-80s\n" "[WARN]" "       Forcing PULL_OLM_INDEX_IMAGE='true' (Directory missing)."
        fi
    fi

    ### Pull Logic
    if [[ "${PULL_OLM_INDEX_IMAGE:-true}" == "true" ]]; then
        ### Cleanup
        podman rmi "$lc_catalog_index" 2>/dev/null || true
        rm -Rf "$lc_catalog_source_dir"/*

        ### Prepare Podman Command Array
        local CMD_ARGS=(
            "podman" "run"
            "--user" "$(id -u):$(id -g)"
            "--authfile" "$PULL_SECRET_FILE"
            "-i" "--rm"
            "-v" "$lc_catalog_source_dir:/mnt:z"
            "--entrypoint" "/bin/sh"
            "$lc_catalog_index"
            "-c" "cp -R /configs/* /mnt/"
        )

        printf "%-8s%-80s\n" "[INFO]" "       > Executing:"
        printf "%-8s%-80s\n" "[INFO]" "           ${CMD_ARGS[*]}"

        ### Execute
        if ! "${CMD_ARGS[@]}" >/dev/null 2>&1; then
             printf "%-8s%-80s\n" "[ERROR]" "       Podman pull/extract failed." >&2
             exit 1
        fi
    else
        printf "%-8s%-80s\n" "[INFO]" "       Skipping pull (PULL_OLM_INDEX_IMAGE=false). Using existing data."
    fi
}

### Helper functions
get_defaultchannel_for_operator() {
    local f="$1"
    [[ -s "$f" ]] || { echo ""; return; }
    if [[ "$f" =~ \.ya?ml$ ]]; then
        ./yq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$f" 2>/dev/null | grep -v "^---$" || echo ""
    else
        jq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$f" 2>/dev/null || echo ""
    fi
}

get_channels_for_operator() {
    local f="$1"
    [[ -s "$f" ]] || { echo ""; return; }
    if [[ "$f" =~ \.ya?ml$ ]]; then
        ./yq -r 'select(.schema == "olm.channel" and .name != null) | .name' "$f" 2>/dev/null | grep -v "^---$" | sort -Vr -u || echo ""
    else
        jq -r 'select(.schema == "olm.channel") | .name // ""' "$f" 2>/dev/null | sort -Vr -u || echo ""
    fi
}

get_versions_for_channel() {
    local chan="$1"
    local f="$2"
    [[ -s "$f" ]] || { echo ""; return; }
    if [[ "$f" =~ \.ya?ml$ ]]; then
        ./yq -r "select(.schema == \"olm.channel\" and .name == \"$chan\") | .entries[] | select(.name) | .name" "$f" 2>/dev/null | sort -Vr -u || echo ""
    else
        jq -r --arg c "$chan" 'select(.schema == "olm.channel" and .name == $c) | .entries[] | select(.name) | .name' "$f" 2>/dev/null | sort -Vr -u || echo ""
    fi
}

get_extract_version() {
    local input_str="$1"
    if [[ -z "$input_str" ]]; then echo ""; return; fi
    if [[ "$input_str" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9_.]+)?)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$input_str" =~ ([0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$input_str" | sed -E 's/^[^0-9]*//'
    fi
}

get_matching_versions() {
    local lc_versions="$1"
    shift
    local lc_specs=("$@")
    local -A match_map=()

    [[ ${#lc_specs[@]} -eq 0 ]] && return
    [[ -z "$lc_versions" ]] && return

    for v in $lc_versions; do
        for s in "${lc_specs[@]}"; do
            if [[ "$s" == "$v" ]]; then
                match_map["$v"]=1
            fi
        done
    done
    if [[ ${#match_map[@]} -gt 0 ]]; then
        printf '%s\n' "${!match_map[@]}" | sort -V
    fi
}

sort_bundles_by_version() {
    local bundles=("$@")
    for b in "${bundles[@]}"; do
        local v_extracted
        v_extracted=$(get_extract_version "$b")
        echo "$v_extracted $b"
    done | LC_ALL=C sort -V | awk '{print $2}'
}

get_string() {
    local lc_string="$1"
    if [[ "$lc_string" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "'$lc_string'"
    else
        echo "$lc_string"
    fi
}

### Creates Detailed Log
create_catalog_info() {
    local lc_cat="$1" lc_src="$2" lc_idx="$3" lc_log="$4"
    local -a lc_ops
    case "$lc_cat" in
        "redhat") lc_ops=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_ops=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_ops=("${COMMUNITY_OPERATORS[@]}");;
        *) printf "%-8s%-80s\n" "[ERROR]" "Invalid catalog '$lc_cat'."; exit 1;;
    esac

    printf "%-8s%-80s\n" "[INFO]" "    -- Generating analysis log for '$lc_cat'..."
    printf "%-8s%-80s\n" "[INFO]" "       Log File: $lc_log"

    echo "Catalog Analysis: $lc_cat" > "$lc_log"
    for op in "${lc_ops[@]}"; do
        [[ -z "$op" ]] && continue
        IFS='|' read -r -a parts <<< "$op"
        op_name="${parts[0]}"

        local catalog_file=""
        for f in ${CATALOG_FILENAMES[@]}; do
            [[ -f "$lc_src/$op_name/$f" ]] && catalog_file="$lc_src/$op_name/$f" && break
        done

        if [[ -z "$catalog_file" ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       Operator '$op_name' not found in catalog. Skipping."
            SKIPPED_OPERATORS+=("$op_name")
            continue
        fi

        {
            echo "======================================================================="
            echo "Operator: $op_name"
            echo "File: $(basename "$catalog_file")"
            echo "======================================================================="
            bash "$operator_channel_info_sh" "$catalog_file"
            echo ""
        } >> "$lc_log" 2>&1
    done
}

### Generate YAML Contents
set_contents() {
    local lc_cat="$1" lc_src="$2" lc_idx="$3" lc_yaml="$4"
    local -a lc_ops
    case "$lc_cat" in
        "redhat") lc_ops=("${REDHAT_OPERATORS[@]}");;
        "certified") lc_ops=("${CERTIFIED_OPERATORS[@]}");;
        "community") lc_ops=("${COMMUNITY_OPERATORS[@]}");;
    esac

    local processed_count=0
    for op in "${lc_ops[@]}"; do
        [[ -z "$op" ]] && continue

        ### 1. Parse Operator & Requested Versions
        IFS='|' read -r -a parts <<< "$op"
        local op_name="${parts[0]}"
        local -a spec_versions=()

        for p in "${parts[@]:1}"; do
            [[ -n "$p" ]] && spec_versions+=("$p")
        done

        ### 2. Find Catalog File
        local catalog_file=""
        for f in ${CATALOG_FILENAMES[@]}; do
            [[ -f "$lc_src/$op_name/$f" ]] && catalog_file="$lc_src/$op_name/$f" && break
        done
        [[ -z "$catalog_file" ]] && continue

        printf "%-8s%-80s\n" "[INFO]" "    -- Processing Operator: $op_name"

        ### 3. Get Default Channel & All Channels
        local def_chan
        def_chan=$(get_defaultchannel_for_operator "$catalog_file")
        if [[ -z "$def_chan" ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       No default channel for '$op_name'. Skipping."
            continue
        fi

        local -a all_channels
        mapfile -t all_channels < <(get_channels_for_operator "$catalog_file")

        ### 4. Start Writing YAML Block
        cat <<EOF >> "$lc_yaml"
    - name: $op_name
      channels:
EOF

        ### 5. Strategy
        local -a remaining_specs=("${spec_versions[@]}")
        local channel_matches_found="false"
        local specific_versions_requested="false"

        if [[ ${#spec_versions[@]} -gt 0 ]]; then
            specific_versions_requested="true"
        fi

        ### Case A: No specific versions requested (Target: Latest)
        if [[ "$specific_versions_requested" == "false" ]]; then
            ### [UPDATED LOG MESSAGE] Corrected to 'Target: Latest'
            printf "%-8s%-80s\n" "[INFO]" "       Adding Default Channel (Target: Latest): $def_chan"
            cat <<EOF >> "$lc_yaml"
      - name: $(get_string "$def_chan")
EOF
            channel_matches_found="true"
        else
            ### Case B: Specific versions requested
            ### Step 5-1: Check Default Channel First
            local def_chan_versions
            def_chan_versions=$(get_versions_for_channel "$def_chan" "$catalog_file")

            local -a found_in_def=()
            mapfile -t found_in_def < <(get_matching_versions "$def_chan_versions" "${remaining_specs[@]}")

            if [[ ${#found_in_def[@]} -gt 0 ]]; then
                printf "%-8s%-80s\n" "[INFO]" "       Found ${#found_in_def[@]} version(s) in Default Channel: $def_chan"

                cat <<EOF >> "$lc_yaml"
      - name: $(get_string "$def_chan")
EOF
                local -a sorted_found_def
                mapfile -t sorted_found_def < <(sort_bundles_by_version "${found_in_def[@]}")

                local min_bundle="${sorted_found_def[0]}"
                local min_ver_str
                min_ver_str=$(get_extract_version "$min_bundle")

                [[ -n "$min_ver_str" ]] && echo "        minVersion: $(get_string "$min_ver_str")" >> "$lc_yaml"

                channel_matches_found="true"

                local -a next_remaining=()
                for rv in "${remaining_specs[@]}"; do
                    local found=0
                    for fv in "${found_in_def[@]}"; do [[ "$rv" == "$fv" ]] && found=1 && break; done
                    [[ $found -eq 0 ]] && next_remaining+=("$rv")
                done
                remaining_specs=("${next_remaining[@]}")
            fi

            ### Step 5-2: Other Channels
            if [[ ${#remaining_specs[@]} -gt 0 ]]; then
                for channel in "${all_channels[@]}"; do
                    [[ "$channel" == "$def_chan" || "$channel" == "candidate" || "$channel" == "---" ]] && continue
                    [[ ${#remaining_specs[@]} -eq 0 ]] && break

                    local chan_versions
                    chan_versions=$(get_versions_for_channel "$channel" "$catalog_file")

                    local -a found_in_chan=()
                    mapfile -t found_in_chan < <(get_matching_versions "$chan_versions" "${remaining_specs[@]}")

                    if [[ ${#found_in_chan[@]} -gt 0 ]]; then
                        printf "%-8s%-80s\n" "[INFO]" "       Found ${#found_in_chan[@]} version(s) in Channel: $channel"

                        cat <<EOF >> "$lc_yaml"
      - name: $(get_string "$channel")
EOF
                        local -a sorted_found_chan
                        mapfile -t sorted_found_chan < <(sort_bundles_by_version "${found_in_chan[@]}")

                        local min_bundle="${sorted_found_chan[0]}"
                        local max_bundle="${sorted_found_chan[-1]}"
                        local min_ver_str
                        min_ver_str=$(get_extract_version "$min_bundle")
                        local max_ver_str
                        max_ver_str=$(get_extract_version "$max_bundle")

                        [[ -n "$min_ver_str" ]] && echo "        minVersion: $(get_string "$min_ver_str")" >> "$lc_yaml"
                        [[ -n "$max_ver_str" ]] && echo "        maxVersion: $(get_string "$max_ver_str")" >> "$lc_yaml"

                        channel_matches_found="true"

                        local -a next_remaining=()
                        for rv in "${remaining_specs[@]}"; do
                            local found=0
                            for fv in "${found_in_chan[@]}"; do [[ "$rv" == "$fv" ]] && found=1 && break; done
                            [[ $found -eq 0 ]] && next_remaining+=("$rv")
                        done
                        remaining_specs=("${next_remaining[@]}")
                    fi
                done
            fi
        fi

        ### 6. Log Missing Versions
        if [[ "$specific_versions_requested" == "true" && ${#remaining_specs[@]} -gt 0 ]]; then
            printf "%-8s%-80s\n" "[WARN]" "       The following versions were NOT found in any valid channel:"
            for v in "${remaining_specs[@]}"; do
                [[ -n "$v" ]] && printf "%-8s%-80s\n" "[WARN]" "       - $v"
            done
        fi

        ### 7. Safety check
        if [[ "$channel_matches_found" == "false" ]]; then
             printf "%-8s%-80s\n" "[WARN]" "       No channels matched the requested versions for '$op_name'."
        fi

        ((processed_count++)) || true
    done

    if [[ $processed_count -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       No packages processed for catalog '$lc_cat'." >&2
        exit 1
    fi
}

### ---------------------------------------------------------------------------------
### 4. Main Logic
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Operator Config Generation ==="

declare -a catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        printf "%-8s%-80s\n" "[INFO]" "--- Processing: $catalog (OCP $major_minor) ---"

        base_dir="$WORK_DIR/oc-mirror"
        src_dir="$base_dir/index/$catalog/$major_minor"
        idx_img="registry.redhat.io/redhat/${catalog}-operator-index:v${major_minor}"
        log_file="$log_dir/olm-${catalog}-${major_minor}.log"
        out_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        yaml_file="$out_dir/imageset-config.yaml"

        imageset_config_files+=("$yaml_file")
        log_files+=("$log_file")

        ### Cleanup & Setup
        if [[ -d "$out_dir" ]]; then rm -rf "$out_dir"; fi
        mkdir -p "$out_dir"

        ### Execute Steps
        pull_catalog_index  "$catalog" "$src_dir" "$idx_img"
        create_catalog_info "$catalog" "$src_dir" "$idx_img" "$log_file"

        ### Write YAML Header
        cat << EOF > "$yaml_file"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
mirror:
  operators:
  - catalog: $idx_img
    packages:
EOF
        set_contents "$catalog" "$src_dir" "$idx_img" "$yaml_file"
    done
done

### ---------------------------------------------------------------------------------
### 5. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Generation Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Files Generated:"
for f in "${imageset_config_files[@]}"; do printf "%-8s%-80s\n" "[INFO]" "    - Config: $f"; done
for f in "${log_files[@]}";             do printf "%-8s%-80s\n" "[INFO]" "    - Log   : $f"; done

if [[ ${#SKIPPED_OPERATORS[@]} -gt 0 ]]; then
    printf "\n%-12s%-80s\n" "[!!WARN!!]" "The following operators were SKIPPED (not found):"
    for op in "${SKIPPED_OPERATORS[@]}"; do
        printf "%-12s%-80s\n" "[!!WARN!!]" "    - $op"
    done
fi
echo ""
