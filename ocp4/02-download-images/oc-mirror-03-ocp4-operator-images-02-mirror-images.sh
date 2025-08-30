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

    ###
    ### Run oc-mirror with specified options
    ###
    "$PWD/oc-mirror" --v2 \
        --authfile      "$PULL_SECRET_FILE" \
        --log-level     "$OC_MIRROR_LOG_LEVEL" \
        --cache-dir     "$OC_MIRROR_CACHE_DIR" \
        --image-timeout "$OC_MIRROR_IMAGE_TIMEOUT" \
        --retry-times   "$OC_MIRROR_RETRY_TIMES" \
        --config        "$lc_imageset_config_file" \
        "file://$lc_oc_mirror_work_dir"
}

##################
### Main Logic ###
##################

extract_ocp_versions

unset catalogs
IFS='|' read -r -a catalogs <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"

### Process mirroring based on the specified strategy

for catalog in "${catalogs[@]}"; do
    for major_minor in "${MAJOR_MINOR_ARRAY[@]}"; do
        oc_mirror_work_dir="$WORK_DIR/export/oc-mirror/olm/$catalog/$major_minor"
        mirror_export_dirs+=("$oc_mirror_work_dir")

        imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

        if [[ -d "$oc_mirror_work_dir/working-dir" ]]; then
            rm -Rf "$oc_mirror_work_dir/working-dir"
        fi
        log "INFO" "Starting individual mirroring for catalog '$catalog' with version: $major_minor"
        mirror_images "$imageset_config_file" "$oc_mirror_work_dir"
        log "INFO" "Individual mirroring completed for catalog '$catalog' with version: $major_minor"
    done
done

### Log completion of the mirroring process
log_echo ""
log      "INFO" "Mirror Images :"
for export_dir in "${mirror_export_dirs[@]}"; do
    log  "INFO" "  $export_dir"
done
log "INFO" "ImageSet configuration generation completed."
log "INFO" "Log File: $log_file"