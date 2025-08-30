#!/bin/bash

### Path to the OpenShift pull secret file
### Defines the location of the pull secret (JSON format) required for accessing OpenShift container registries
### Example: "$HOME/pull-secret.txt" (ensure the file exists and contains valid credentials)
PULL_SECRET_FILE="$PWD/pull-secret.txt"

### OpenShift versions to be mirrored (use '--' as a separator)
### Specifies the OpenShift versions to mirror, prefixed with a channel type (e.g., fast, stable(default), eus)
### Example: "stable-4.17.9--4.17.25--eus-4.18.10" will mirror versions 4.17.9, 4.17.21, and 4.18.10
OCP_VERSIONS="4.19.9"

### ----------------------------------------
### Container Images
### Define necessary container images for additional tools and logging
### ----------------------------------------

### OpenShift Graph Data (Upgrade Paths)
### This function generates a Dockerfile to fetch and extract Cincinnati graph data for OpenShift upgrade paths
### Purpose: Provides version upgrade information used by oc-mirror for mirroring
### Usage: Run "docker build -t cincinnati-graph-data ." after calling this function
create_dockerfile() {
    cat << EOF > ./Dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN curl -L -o cincinnati-graph-data.tar.gz https://api.openshift.com/api/upgrades_info/graph-data
RUN mkdir -p /var/lib/cincinnati-graph-data && tar xvzf cincinnati-graph-data.tar.gz -C /var/lib/cincinnati-graph-data/ --no-overwrite-dir --no-same-owner
CMD ["/bin/bash", "-c", "exec cp -rp /var/lib/cincinnati-graph-data/* /var/lib/cincinnati/graph-data"]
EOF
}

### Event Router image (used for event logging in OpenShift)
### Specifies the container image for the event router used in OpenShift logging (v0.4 is the stable release)
EVENTROUTER_IMAGE="registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4"

### Support Tools image (provides debugging utilities)
### Defines the container image for support tools, offering debugging utilities for OpenShift
SUPPORT_TOOL_IMAGE="registry.redhat.io/rhel9/support-tools:latest"

### ----------------------------------------
### OpenShift Client Tool
### ----------------------------------------
### Tarball file names for oc-mirror on RHEL8 and RHEL9
###   OPENSHIFT_CLIENT_DOWNLOAD_URL/$latest_version/$OPENSHIFT_CLIENT_RHEL9_FILE"
OPENSHIFT_CLIENT_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp"
OPENSHIFT_CLIENT_RHEL8_FILE="openshift-client-linux-amd64-rhel8.tar.gz"
OPENSHIFT_CLIENT_RHEL9_FILE="openshift-client-linux-amd64-rhel9.tar.gz"

### ----------------------------------------
### OpenShift Mirror Tool
### ----------------------------------------
### Tarball file names for oc-mirror on RHEL8 and RHEL9
### Defines the tarball filenames for the oc-mirror tool, differing by RHEL version (RHEL8 uses gz, RHEL9 uses rhel9-specific tar)
OC_MIRROR_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable"
OC_MIRROR_RHEL8_TAR="oc-mirror.tar.gz"
OC_MIRROR_RHEL9_TAR="oc-mirror.rhel9.tar.gz"

### butane tool
BUTANE_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane"

### ----------------------------------------
### Operator Lifecycle Manager (OLM) Configurations
### Defines operator catalogs and specific operators to mirror
### ----------------------------------------

### Operator catalog sources
### Specifies which operator catalogs to mirror (e.g., "redhat", "certified", "community")
### Format: Combination using "--" as a separator (e.g., "redhat--certified")
### Default Value: "redhat" (if not specified)
OLM_CATALOGS="redhat"
OLM_CATALOGS="redhat--certified"

### Flag to pull OLM index image
### Controls whether to pull the OLM index image during mirroring
### Values: "true" (default), "false" (For test only)
### Note: Set to "false" for testing; requires at least one prior run with OCP_VERSIONS set
PULL_OLM_INDEX_IMAGE="false"

### List of Red Hat Operators to mirror
### Check used versions with: oc get csv -A |awk '{print $2}' |egrep -Ev "packageserver|NAME" |sort |uniq
### Format: "operator[|current_csv_name|...|current_csv_name]"
### Example: ("cincinnati-operator" "openshift-gitops-operator|openshift-gitops-operator.v1.14.2")

###########################################################################
### Test Case #1: Default Channel is the Highest Version with Multiple Operators
REDHAT_OPERATORS=("openshift-gitops-operator")
REDHAT_OPERATORS=("openshift-gitops-operator|openshift-gitops-operator.v1.14.2")
REDHAT_OPERATORS=("openshift-gitops-operator|openshift-gitops-operator.v1.6.6")
REDHAT_OPERATORS=("openshift-gitops-operator|openshift-gitops-operator.v1.14.2|openshift-gitops-operator.v1.13.5|openshift-gitops-operator.v1.15.0|openshift-gitops-operator.v1.6.6")
### Test Case #2: Default Channel is Not the Highest Version with Multiple Operators
REDHAT_OPERATORS=("lvms-operator")
REDHAT_OPERATORS=("lvms-operator|lvms-operator.v4.16.7")
REDHAT_OPERATORS=("lvms-operator|lvms-operator.v4.17.4")
REDHAT_OPERATORS=("lvms-operator|lvms-operator.v4.17.4|lvms-operator.v4.16.7")
##########################################################################

REDHAT_OPERATORS=(
    "cincinnati-operator"
    "cluster-logging"
    "devworkspace-operator"
    "kubernetes-nmstate-operator"
    "loki-operator"
    "netobserv-operator"
    "node-healthcheck-operator"
    "node-maintenance-operator"
    "openshift-gitops-operator"
    "openshift-pipelines-operator-rh"
    "rhbk-operator"
    "self-node-remediation"
    "web-terminal"
)

### List of Certified Operators to mirror
### Specifies certified operators to include in the mirroring process
CERTIFIED_OPERATORS=(
    "elasticsearch-eck-operator-certified"
)

### List of Community Operators to mirror
### Specifies community operators to include in the mirroring process
COMMUNITY_OPERATORS=("")

### Define the base working directory
### Purpose: Base directory for storing mirrored images and configuration files
### Default Value: Current directory combined with OCP_VERSIONS if not explicitly set
###                "$(realpath $PWD)/$OCP_VERSIONS"
WORK_DIR=""

### Define the tool directory
### Default Value: Subdirectory for tool binaries under WORK_DIR
###                "$WORK_DIR/export/tool-binaries"
TOOL_DIR=""

### Define the oc-mirror cache directory
### Default Value: Cache directory for oc-mirror under WORK_DIR
###                "$PWD"
OC_MIRROR_CACHE_DIR=""

### Define the directory for additional OCP tool images
### Default Value: Directory for storing additional container images under WORK_DIR
###                "$WORK_DIR/export/additional-images"
OCP_TOOL_IMAGE_DIR=""

### ----------------------------------------
### OpenShift Mirror Tool Configuration
### Defines runtime settings for the oc-mirror tool
### ----------------------------------------
### Log level for oc-mirror
### Options: "info", "debug", "trace", "error"
### Default Value: "info"
OC_MIRROR_LOG_LEVEL=""

### Timeout for mirroring an image
### Specifies the maximum time allowed to mirror a single image
### Default Value: "60m0s" (60 minutes)
OC_MIRROR_IMAGE_TIMEOUT=""

### Number of retry attempts for mirroring
### Defines how many times to retry mirroring an image on failure
### Default Value: 7
OC_MIRROR_RETRY_TIMES=""


### ----------------------------------------
### Validate Input Parameters
### Set up directories for work, tools, and images
### ----------------------------------------
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    echo "[ERROR] Pull secret file $PULL_SECRET_FILE does not exist. Exiting..."
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "[ERROR] jq command not found. Please install jq. Exiting..."
    exit 1
fi

### Allow OCP_VERSIONS to be passed as a command-line argument if not set
### Note: Command-line argument ($1) overrides environment variable if provided
OCP_VERSIONS="${OCP_VERSIONS:-"$1"}"
if [[ -z "${OCP_VERSIONS}" ]]; then
    echo -e "ERROR: OCP_VERSIONS is not set.\n"
    echo "Please specify OpenShift versions using '--' as a separator."
    echo "Usage: $0 <OCP versions>"
    echo -e "Examples:\n  $0 eus--4.17.9\n  $0 stable-4.17.9--4.17.21--eus-4.18.10"
    exit 1
fi

### Define Default Value
PULL_OLM_INDEX_IMAGE="${PULL_OLM_INDEX_IMAGE:-"true"}"
OLM_CATALOGS="${OLM_CATALOGS:-"redhat"}"

OC_MIRROR_LOG_LEVEL="${OC_MIRROR_LOG_LEVEL:-"info"}"
OC_MIRROR_IMAGE_TIMEOUT="${OC_MIRROR_IMAGE_TIMEOUT:-"60m0s"}"
OC_MIRROR_RETRY_TIMES="${OC_MIRROR_RETRY_TIMES:-7}"

WORK_DIR="${WORK_DIR:-"$(realpath $PWD)/$OCP_VERSIONS"}"
TOOL_DIR="${TOOL_DIR:-"$WORK_DIR/export/tool-binaries"}"
OC_MIRROR_CACHE_DIR="${OC_MIRROR_CACHE_DIR:-"$PWD"}"
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

################
### Function ###
################

### Set up logging directory and file
log_dir="$WORK_DIR/logs"
log_file="$log_dir/oc-mirror-sh-$(date +%Y%m%d-%H%M%S).log"
if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" || {
        echo "[ERROR] Failed to create log directory $log_dir. Exiting..."
        exit 1
    }
fi
touch "$log_file" || { echo "[ERROR] Failed to create log file $log_file. Exiting..."; exit 1; }

### Function to log messages
log() {
    local lc_level="$1" lc_msg="$2"
    printf "%-7s %s\n" "[$lc_level]" "$lc_msg" | tee -a "$log_file"
}
log_echo() {
    local lc_msg="$1" lc_flag="$2"
    if [[ "$lc_flag" == "new" ]]; then
        echo "$lc_msg" | tee "$log_file"
    else
        echo "$lc_msg" | tee -a "$log_file"
    fi
}
log_to_file() {
    local lc_level="$1" lc_msg="$2"
    printf "%-7s %s\n" "[$lc_level]" "$lc_msg" >> "$log_file"
}
log_operator_info() {
    local lc_level="$1" lc_msg="$2" lc_log_file="$3"
    if [[ -z "$lc_log_file" ]]; then
        log "ERROR" "Log file path is empty in log_operator_info. Skipping..."
        return 1
    fi
    printf "%-7s %s\n" "[$lc_level]" "$lc_msg" >> "$lc_log_file" || {
        log "ERROR" "Failed to append to $lc_log_file. Exiting..."
        exit 1
    }
}
log_echo_operator_info() {
    local lc_msg="$1" lc_flag="$2" lc_log_file="$3"
    if [[ -z "$lc_log_file" ]]; then
        log "ERROR" "Log file path is empty in log_echo_operator_info. Skipping..."
        return 1
    fi
    if [[ "$lc_flag" == "new" ]]; then
        echo "$lc_msg" > "$lc_log_file" || {
            log "ERROR" "Failed to write to $lc_log_file. Exiting..."
            exit 1
        }
    else
        echo "$lc_msg" >> "$lc_log_file" || {
            log "ERROR" "Failed to append to $lc_log_file. Exiting..."
            exit 1
        }
    fi
}

### Declare arrays and associative arrays as global variables
### Function to extract OCP versions and populate global arrays
declare -a OCP_VERSION_ARRAY     # Array to store OCP versions (e.g., 4.17.9, 4.17.21)
declare -A CHANNEL_TO_VERSIONS   # Associative array to map channels to OCP versions (e.g., stable-4.17 -> 4.17.9 4.17.21)
declare -a MAJOR_MINOR_ARRAY     # Array to store unique major-minor versions (e.g., 4.17, 4.18)
extract_ocp_versions() {
    if [[ -z "$OCP_VERSIONS" ]]; then
        log "ERROR" "OCP_VERSIONS is empty. Exiting..."
        exit 1
    fi
    local lc_default_channel_prefix="stable"
    local lc_prefix lc_version lc_channel lc_mm_version
    local -A temp_unique_mm_versions
    local -A temp_channel_versions
    local -a temp_version_array

    log "INFO" "Processing OCP_VERSIONS: $OCP_VERSIONS"
    IFS='|' read -r -a lc_version_entries <<< "${OCP_VERSIONS//--/|}"

    for lc_entry in "${lc_version_entries[@]}"; do
        if [[ "$lc_entry" =~ ^([a-z]+-)?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            lc_prefix="${BASH_REMATCH[1]}"
            lc_version="${BASH_REMATCH[2]}"
            if [[ -n "$lc_prefix" ]]; then
                lc_channel="${lc_prefix}${lc_version%.*}"
            else
                lc_channel="${lc_default_channel_prefix}-${lc_version%.*}"
            fi
            temp_version_array+=("$lc_version")
            if [[ -n "${temp_channel_versions[$lc_channel]}" ]]; then
                temp_channel_versions["$lc_channel"]="${temp_channel_versions[$lc_channel]} $lc_version"
            else
                temp_channel_versions["$lc_channel"]="$lc_version"
            fi
            lc_mm_version="${lc_version%.*}"
            temp_unique_mm_versions["$lc_mm_version"]=1
        else
            log "WARN" "Invalid version format: $lc_entry. Skipping..."
        fi
    done

    if [[ ${#temp_version_array[@]} -eq 0 ]]; then
        log "ERROR" "No valid versions found in OCP_VERSIONS. Exiting..."
        exit 1
    fi

    mapfile -t OCP_VERSION_ARRAY < <(printf '%s\n' "${temp_version_array[@]}" | sort -V | uniq)
    for lc_channel in "${!temp_channel_versions[@]}"; do
        mapfile -t sorted_versions < <(echo "${temp_channel_versions[$lc_channel]}" | tr ' ' '\n' | sort -V | uniq)
        CHANNEL_TO_VERSIONS["$lc_channel"]="${sorted_versions[*]}"
    done
    mapfile -t MAJOR_MINOR_ARRAY < <(printf '%s\n' "${!temp_unique_mm_versions[@]}" | sort -V)

    if [[ ${#MAJOR_MINOR_ARRAY[@]} -eq 0 ]]; then
        log "ERROR" "MAJOR_MINOR_ARRAY is empty after processing. Exiting..."
        exit 1
    fi

    log "INFO" "Extracted OCP versions: ${OCP_VERSION_ARRAY[*]}"
    log "INFO" "Channel mappings: $(for key in "${!CHANNEL_TO_VERSIONS[@]}"; do echo "$key=${CHANNEL_TO_VERSIONS[$key]}"; done | tr '\n' ' ')"
    log "INFO" "Major-minor versions: ${MAJOR_MINOR_ARRAY[*]}"

    unset temp_unique_mm_versions temp_channel_versions temp_version_array
}

### Get channel for a given major-minor-patch version
get_channel_by_version() {
    local input_version="$1"  # Input in major-minor-patch format (e.g., 4.17.9)
    
    # Find the channel containing this version
    for channel in "${!CHANNEL_TO_VERSIONS[@]}"; do
        IFS=' ' read -r -a versions <<< "${CHANNEL_TO_VERSIONS[$channel]}"
        for version in "${versions[@]}"; do
            if [[ "$version" == "$input_version" ]]; then
                echo "$channel"
                return 0
            fi
        done
    done

    # This should not happen if version is in OCP_VERSION_ARRAY, but added for safety
    echo "Error: No channel found for version $input_version" >&2
    return 1
}