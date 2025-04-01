#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

unset mirror_export_dirs
declare -a mirror_export_dirs

### Check if pull_secret file exists and apply its contents
### Ensure the pull secret file is available for authentication
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    echo "[ERROR]: Cannot access $PULL_SECRET_FILE. File does not exist. Exiting..."
    exit 1
fi

### Validate that OCP_VERSIONS is set and not empty
if [[ -z "$OCP_VERSIONS" ]]; then
    echo "[ERROR]: OCP_VERSIONS is not set or empty. Exiting..."
    exit 1
fi

### Check if oc-mirror binary exists in the current directory
if [[ ! -f "$PWD/oc-mirror" ]]; then
    echo "[ERROR]: Cannot access './oc-mirror' at $PWD/oc-mirror. File does not exist. Exiting..."
    exit 1
fi

### Ensure the oc-mirror cache directory exists
if [[ ! -d "$OC_MIRROR_CACHE_DIR" ]]; then
    mkdir -p "$OC_MIRROR_CACHE_DIR" && chmod 755 "$OC_MIRROR_CACHE_DIR"
    if [[ $? -ne 0 ]]; then
        echo "[ERROR]: Failed to create cache directory $OC_MIRROR_CACHE_DIR. Exiting..."
        exit 1
    fi
fi

### Mirror Images Function
### Execute oc-mirror to mirror images with specified configuration and work directory
mirror_images() {
    local lc_imageset_config_file="$1"
    local lc_oc_mirror_work_dir="$2"

    ### Validate that the imageset config file exists
    if [[ ! -f "$lc_imageset_config_file" ]]; then
        log "ERROR" "ImageSet configuration file $lc_imageset_config_file not found. Exiting..."
        exit 1
    fi

    ### Validate that the work directory exists
    if [[ ! -d "$lc_oc_mirror_work_dir" ]]; then
        log "ERROR" "Work directory $lc_oc_mirror_work_dir not found. Exiting..."
        exit 1
    fi

    log_echo ""
    log "INFO" "authfile      : $PULL_SECRET_FILE"
    log "INFO" "log-level     : $OC_MIRROR_LOG_LEVEL"
    log "INFO" "cache-dir     : $OC_MIRROR_CACHE_DIR"
    log "INFO" "image-timeout : $OC_MIRROR_IMAGE_TIMEOUT"
    log "INFO" "retry-times   : $OC_MIRROR_RETRY_TIMES"
    log "INFO" "config        : $lc_imageset_config_file"
    log "INFO" "destination   : file://$lc_oc_mirror_work_dir"
    log_echo ""

    ### Run oc-mirror with specified options
    "$PWD/oc-mirror" --v2 \
        --authfile      "$PULL_SECRET_FILE" \
        --log-level     "$OC_MIRROR_LOG_LEVEL" \
        --cache-dir     "$OC_MIRROR_CACHE_DIR" \
        --image-timeout "$OC_MIRROR_IMAGE_TIMEOUT" \
        --retry-times   "$OC_MIRROR_RETRY_TIMES" \
        --config        "$lc_imageset_config_file" \
        "file://$lc_oc_mirror_work_dir"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to mirror images with config $lc_imageset_config_file. Exiting..."
        exit 1
    fi
}

##################
### Main Logic ###
##################

extract_ocp_versions

unset catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

### Process mirroring based on the specified strategy
if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    ### Aggregated mode: Mirror all versions for each catalog in a single operation
    for catalog in "${catalogs[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$MIRROR_STRATEGY"
        mirror_export_dirs+=("$oc_mirror_work_dir")

        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            rm -Rf "$oc_mirror_work_dir/working-dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to delete directory $oc_mirror_work_dir."
                exit 1
            fi
        fi
        log "INFO" "Starting aggregated mirroring for catalog '$catalog'"
        mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
        log "INFO" "Aggregated mirroring completed for catalog '$catalog'"
    done
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    ### Incremental mode: Mirror versions step-by-step for each catalog
    for catalog in "${catalogs[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/oc-mirror/olm/$catalog/$MIRROR_STRATEGY"

        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            rm -Rf "$oc_mirror_work_dir/working-dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to delete directory $oc_mirror_work_dir."
                exit 1
            fi
        fi

        for ((i=0; i<${#MAJOR_MINOR_ARRAY[@]}; i++)); do
            current_versions=("${MAJOR_MINOR_ARRAY[@]:0:$((i+1))}")
            version_string=$(echo "${current_versions[*]}" | sed 's/ /--/g')

            imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"

            target_oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$MIRROR_STRATEGY/$version_string"
            mirror_export_dirs+=("$target_oc_mirror_work_dir")

            if [[ -d "$target_oc_mirror_work_dir" ]]; then
                rm -Rf "$target_oc_mirror_work_dir"
                if [[ $? -ne 0 ]]; then
                    log "ERROR" "Failed to delete directory $target_oc_mirror_work_dir."
                fi
            fi

            log "INFO" "Starting incremental mirroring for catalog '$catalog' with versions: $version_string"
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir"

            ### Copy results to export directory
            mkdir -p "$target_oc_mirror_work_dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to create directory $target_oc_mirror_work_dir. Exiting..."
                exit 1
            fi
            cp -Rf "$oc_mirror_work_dir"/* "$target_oc_mirror_work_dir/"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to copy files to $target_oc_mirror_work_dir. Exiting..."
                exit 1
            fi
            log "INFO" "Incremental mirroring completed for catalog '$catalog' with versions: $version_string"
        done
        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            rm -Rf "$oc_mirror_work_dir/working-dir"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to delete directory $oc_mirror_work_dir."
            fi
        fi
        if [[ -f "$oc_mirror_work_dir/mirror_000001.tar" ]]; then
            rm -f "$oc_mirror_work_dir/mirror_000001.tar"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to delete file "$oc_mirror_work_dir/mirror_000001.tar"."
            fi
        fi
    done
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    ### Individual mode: Mirror each version separately for each catalog
    for catalog in "${catalogs[@]}"; do
        for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
            oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$MIRROR_STRATEGY/$major_minor"
            mirror_export_dirs+=("$oc_mirror_work_dir")

            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

            if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
                rm -Rf "$oc_mirror_work_dir/working-dir"
                if [[ $? -ne 0 ]]; then
                    log "ERROR" "Failed to delete directory $oc_mirror_work_dir/working-dir. Exiting..."
                    exit 1
                fi
            fi
            log "INFO" "Starting individual mirroring for catalog '$catalog' with version: $major_minor"
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
            log "INFO" "Individual mirroring completed for catalog '$catalog' with version: $major_minor"
        done
    done
else
    ### Handle invalid MIRROR_STRATEGY value
    log "ERROR" "Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'. Exiting..."
    exit 1
fi

### Log completion of the mirroring process
log_echo ""
log      "INFO" "Mirror Images :"
for export_dir in "${mirror_export_dirs[@]}"; do
    log  "INFO" "  $export_dir"
done
log "INFO" "ImageSet configuration generation completed."
log "INFO" "Log File: $log_file"
