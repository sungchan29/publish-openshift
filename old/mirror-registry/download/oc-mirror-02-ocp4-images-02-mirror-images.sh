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
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    ### If pull secret file does not exist, log error and exit
    echo "[ERROR] Cannot access $PULL_SECRET_FILE. File does not exist. Exiting..."
    exit 1
fi

### Check if oc-mirror binary exists
if [[ ! -f $PWD/oc-mirror ]]; then
    echo "[ERROR] Cannot access './oc-mirror'. File does not exist. Exiting..."
    exit 1
fi

if [[ ! -d $OC_MIRROR_CACHE_DIR ]]; then
    mkdir -p $OC_MIRROR_CACHE_DIR
fi

###
### Main Function (Logic)
###

mirror_images() {
    local lc_imageset_config_file="$1"
    local lc_oc_mirror_work_dir="$2"

    log_echo ""
    log "INFO" "MIRROR_STRATEGY : $MIRROR_STRATEGY"
    log "INFO" "authfile        : $PULL_SECRET_FILE"
    log "INFO" "log-level       : $OC_MIRROR_LOG_LEVEL"
    log "INFO" "cache-dir       : $OC_MIRROR_CACHE_DIR"
    log "INFO" "image-timeout   : $OC_MIRROR_IMAGE_TIMEOUT"
    log "INFO" "retry-times     : $OC_MIRROR_RETRY_TIMES"
    log "INFO" "config          : $lc_imageset_config_file"
    log "INFO" "file://$lc_oc_mirror_work_dir"

    $PWD/oc-mirror --v2 \
        --authfile      "$PULL_SECRET_FILE" \
        --log-level     "$OC_MIRROR_LOG_LEVEL" \
        --cache-dir     "$OC_MIRROR_CACHE_DIR" \
        --image-timeout "$OC_MIRROR_IMAGE_TIMEOUT" \
        --retry-times   "$OC_MIRROR_RETRY_TIMES" \
        --config        "$lc_imageset_config_file" \
        file://"$lc_oc_mirror_work_dir"
}

##################
### Main logic ###
##################

extract_ocp_versions

if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
    ### Aggregated mode: Single file with all versions
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d $oc_mirror_work_dir/working-dir ]]; then
        rm -Rf $oc_mirror_work_dir/working-dir
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to delete directory. $oc_mirror_work_dir/working-dir. Exiting..."
            exit 1
        fi
    fi

    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    mirror_export_dirs+=("$oc_mirror_work_dir")

    if [[ -f "$imageset_config_file" ]]; then
        ### Mirror Images
        mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
    else
        log "ERROR" "ImageSet configuration file $imageset_config_file not found. Exiting..."
        exit 1
    fi
elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
    oc_mirror_work_dir="$WORK_DIR/oc-mirror/ocp/$MIRROR_STRATEGY"
    if [[ -d $oc_mirror_work_dir/working-dir ]]; then
        rm -Rf $oc_mirror_work_dir/working-dir
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to delete directory. $oc_mirror_work_dir/working-dir. Exiting..."
            exit 1
        fi
    fi

    target_oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY"
    mirror_export_dirs+=("$target_oc_mirror_work_dir")

    if [[ -d "$target_oc_mirror_work_dir" ]]; then
        rm -Rf "$target_oc_mirror_work_dir"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to delete directory. $target_oc_mirror_work_dir. Exiting..."
            exit 1
        fi
    fi

    ### Generate files incrementally
    for ((i=0; i<${#OCP_VERSION_ARRAY[@]}; i++)); do
        current_versions=("${OCP_VERSION_ARRAY[@]:0:$((i+1))}")
        version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

        imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"
        if [[ -f "$imageset_config_file" ]]; then
            ### Mirror Images
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir"

            mkdir -p "$target_oc_mirror_work_dir/$version_string"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to create directory $target_oc_mirror_work_dir. Exiting..."
                exit 1
            fi
            log_echo ""
            cp -Rf "$oc_mirror_work_dir/"* "$target_oc_mirror_work_dir/$version_string/"
            log_echo ""
        else
            log "ERROR" "ImageSet configuration file $imageset_config_file not found. Exiting..."
            exit 1
        fi
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
elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
    for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
        ### Individual mode: One file per version
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$MIRROR_STRATEGY/$major_minor_patch"
        mirror_export_dirs+=("$oc_mirror_work_dir")
        if [[ -d $oc_mirror_work_dir/working-dir ]]; then
            rm -Rf $oc_mirror_work_dir/working-dir
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to delete directory. $oc_mirror_work_dir/working-dir. Exiting..."
                exit 1
            fi
        fi

        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
        if [[ -f "$imageset_config_file" ]]; then
            ### Mirror Images
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
        else
            log "ERROR" "ImageSet configuration file $imageset_config_file not found. Exiting..."
            exit 1
        fi
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