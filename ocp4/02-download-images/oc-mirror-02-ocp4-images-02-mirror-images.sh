#!/bin/bash

### Source configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    log "ERROR" "Cannot access config file at $config_file. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"

### Validate required files and directories
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    log "ERROR" "Cannot access pull secret file at $PULL_SECRET_FILE. File does not exist. Exiting..."
    exit 1
fi
if [[ ! -f "$PWD/oc-mirror" ]]; then
    log "ERROR" "Cannot access './oc-mirror' binary. File does not exist. Exiting..."
    exit 1
fi
if [[ ! -d "$OC_MIRROR_CACHE_DIR" ]]; then
    mkdir -p "$OC_MIRROR_CACHE_DIR" || {
        log "ERROR" "Failed to create cache directory $OC_MIRROR_CACHE_DIR. Exiting..."
        exit 1
    }
fi

### Declare array to store mirror export directories
unset mirror_export_dirs
declare -a mirror_export_dirs

### Function to mirror images using oc-mirror
mirror_images() {
    local lc_imageset_config_file="$1"
    local lc_oc_mirror_work_dir="$2"

    ### Log mirroring configuration
    log_echo ""
    log "INFO" "authfile       : $PULL_SECRET_FILE"
    log "INFO" "log-level      : $OC_MIRROR_LOG_LEVEL"
    log "INFO" "cache-dir      : $OC_MIRROR_CACHE_DIR"
    log "INFO" "image-timeout  : $OC_MIRROR_IMAGE_TIMEOUT"
    log "INFO" "retry-times    : $OC_MIRROR_RETRY_TIMES"
    log "INFO" "config         : $lc_imageset_config_file"
    log "INFO" "destination    : file://$lc_oc_mirror_work_dir"

    ###
    ### Execute oc-mirror command
    ###
    "$PWD/oc-mirror" --v2 \
        --authfile      "$PULL_SECRET_FILE" \
        --log-level     "$OC_MIRROR_LOG_LEVEL" \
        --cache-dir     "$OC_MIRROR_CACHE_DIR" \
        --image-timeout "$OC_MIRROR_IMAGE_TIMEOUT" \
        --retry-times   "$OC_MIRROR_RETRY_TIMES" \
        --config        "$lc_imageset_config_file" \
        file://"$lc_oc_mirror_work_dir" || {
        log "ERROR" "oc-mirror failed for $lc_imageset_config_file. Exiting..."
        exit 1
    }
}

### Main logic
extract_ocp_versions

for major_minor_patch in "${OCP_VERSION_ARRAY[@]}"; do
    oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/ocp/$major_minor_patch"
    mirror_export_dirs+=("$oc_mirror_work_dir")

    if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
        ### Remove existing working directory
        log "INFO" "Removing existing working directory $oc_mirror_work_dir/working-dir"
        chmod -R u+w "$oc_mirror_work_dir/working-dir" 2>/dev/null || log "WARN" "Failed to set write permissions on $oc_mirror_work_dir/working-dir. Continuing..."
        rm -Rf "$oc_mirror_work_dir/working-dir" || {
            log "ERROR" "Failed to delete directory $oc_mirror_work_dir/working-dir. Exiting..."
            exit 1
        }
    fi

    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
    if [[ -f "$imageset_config_file" ]]; then
        ### Mirror images
        mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
    else
        log "ERROR" "ImageSet configuration file $imageset_config_file not found. Exiting..."
        exit 1
    fi
done

### Log completion of mirroring process
log_echo ""
log "INFO" "Mirror Images completed:"
for export_dir in "${mirror_export_dirs[@]}"; do
    log "INFO" "  $export_dir"
    ls -lh "$export_dir" | grep -v "^total" || {
        log "ERROR" "Failed to list files in $export_dir. Exiting..."
        exit 1
    }
done
log "INFO" "Log File: $log_file"
log_echo ""