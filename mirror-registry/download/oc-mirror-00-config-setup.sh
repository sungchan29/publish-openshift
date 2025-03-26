#!/bin/bash

### Path to the OpenShift pull secret file
### Defines the location of the pull secret (JSON format) required for accessing OpenShift container registries
### Example: "$HOME/pull-secret.txt" (ensure the file exists and contains valid credentials)
PULL_SECRET_FILE="$HOME/Downloads/ocp/pull-secret.txt"

### OpenShift versions to be mirrored (use '--' as a separator)
### Specifies the OpenShift versions to mirror, prefixed with a channel type (e.g., fast, stable(default), eus)
### Example: "stable-4.17.9--4.17.21--eus-4.18.10" will mirror versions 4.17.9, 4.17.21, and 4.18.10
OCP_VERSIONS="4.17.9--4.17.20"


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
### OpenShift Mirror Tool
### Configurations for mirroring OpenShift release images and operators
### Supports mirroring of OpenShift release images and Operator Lifecycle Manager (OLM) operators
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

### MIRROR_STRATEGY: Defines the mirroring strategy for OCP and Operator images
### Purpose: Controls how ImageSetConfiguration YAML files are generated
### Values:
###   - "aggregated": Single YAML file with all versions combined
###   - "incremental": Cumulative YAML files, adding versions step-by-step
###   - "individual": Separate YAML file per version
### Default Value: "incremental" (if not specified)
MIRROR_STRATEGY=""

### Operator catalog sources
### Specifies which operator catalogs to mirror (e.g., "redhat", "certified", "community")
### Format: Combination using "--" as a separator (e.g., "redhat--certified")
### Default Value: "redhat" (if not specified)
OLM_CATALOGS="redhat--certified"

### Flag to pull OLM index image
### Controls whether to pull the OLM index image during mirroring
### Values: "true" (default), "false" (For test only)
### Note: Set to "false" for testing; requires at least one prior run with OCP_VERSIONS set
PULL_OLM_INDEX_IMAGE="false"

### List of Red Hat Operators to mirror
### Format: "operator|used_version::operator|used_version::..." (use '::' to separate operators, '|' for version)
### Note: If version is omitted after '|', the latest version is mirrored
### Example: "advanced-cluster-management|2.2::kiali-ossm" (mirrors v2.2 and latest kiali-ossm)

###########################################################################
### Test Case #1: Default Channel is the Highest Version with Multiple Operators
REDHAT_OPERATORS="openshift-gitops-operator"
REDHAT_OPERATORS="openshift-gitops-operator|openshift-gitops-operator.v1.14.2"
REDHAT_OPERATORS="openshift-gitops-operator|openshift-gitops-operator.v1.6.6"
REDHAT_OPERATORS="openshift-gitops-operator|openshift-gitops-operator.v1.14.2|openshift-gitops-operator.v1.13.5|openshift-gitops-operator.v1.15.0|openshift-gitops-operator.v1.6.6"
### Test Case #2: Default Channel is Not the Highest Version with Multiple Operators
REDHAT_OPERATORS="lvms-operator"
REDHAT_OPERATORS="lvms-operator|lvms-operator.v4.16.7"
REDHAT_OPERATORS="lvms-operator|lvms-operator.v4.17.4"
REDHAT_OPERATORS="lvms-operator|lvms-operator.v4.17.4|lvms-operator.v4.16.7"
##########################################################################

#::openshift-custom-metrics-autoscaler-operator|custom-metrics-autoscaler.v2.14.1-467\
#::local-storage-operator|local-storage-operator.v4.17.0-202412170235\
#::lvms-operator|lvms-operator.v4.17.3\
#::node-observability-operator|node-observability-operator.v0.2.0\
#::vertical-pod-autoscaler|verticalpodautoscaler.v4.17.0-202412170235\

REDHAT_OPERATORS="\
advanced-cluster-management|advanced-cluster-management.v2.12.1\
::cincinnati-operator|update-service-operator.v5.0.3\
::cluster-logging|cluster-logging.v6.1.0\
::devworkspace-operator|devworkspace-operator.v0.31.2\
::jaeger-product|jaeger-operator.v1.62.0-1\
::kiali-ossm|kiali-operator.v1.89.10\
::kubernetes-nmstate-operator|kubernetes-nmstate-operator.4.17.0-202412180037\
::multicluster-engine|multicluster-engine.v2.7.2\
::netobserv-operator|network-observability-operator.v1.7.0\
::nfd\
::node-healthcheck-operator|node-healthcheck-operator.v0.8.2\
::node-maintenance-operator|node-maintenance-operator.v5.3.1\
::openshift-gitops-operator|openshift-gitops-operator.v1.15.0\
::opentelemetry-product|opentelemetry-operator.v0.113.0-1\
::self-node-remediation|self-node-remediation.v0.9.0\
::servicemeshoperator|servicemeshoperator.v2.6.4\
::tempo-product|tempo-operator.v0.14.1-1\
::web-terminal|web-terminal.v1.12.1\
"

### List of Certified Operators to mirror
### Specifies certified operators to include in the mirroring process
CERTIFIED_OPERATORS="\
gpu-operator-certified\
"

### List of Community Operators to mirror
### Specifies community operators to include in the mirroring process
COMMUNITY_OPERATORS="\
gitlab-operator-kubernetes\
"

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
MIRROR_STRATEGY="${MIRROR_STRATEGY:-"incremental"}"
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
log_file="$log_dir/oc-mirror-sh.log"
if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" || {
        echo "[ERROR] Failed to create log directory $log_dir. Exiting..."
        exit 1
    }
fi
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

### Declare arrays and associative arrays as global variables
### Function to extract OCP versions and populate global arrays
declare -a OCP_VERSION_ARRAY     # Array to store OCP versions (e.g., 4.17.9, 4.17.21)
declare -A CHANNEL_TO_VERSIONS   # Associative array to map channels to OCP versions (e.g., stable-4.17 -> 4.17.9 4.17.21)
declare -a MAJOR_MINOR_ARRAY     # Array to store unique major-minor versions (e.g., 4.17, 4.18)
extract_ocp_versions() {
    local lc_default_channel_prefix="stable"
    local lc_prefix
    local lc_version
    local lc_channel
    local lc_mm_version
    local -A temp_unique_mm_versions  # Temporary local associative array for unique major-minor versions
    local -A temp_channel_versions    # Temporary local associative array for channel-to-versions mapping
    local -a temp_version_array       # Temporary local array for OCP versions

    ### Split ocp_versions into an array using '--' as the delimiter
    IFS='|' read -r -a lc_version_entries <<< "${OCP_VERSIONS//--/|}"

    ### Process each version entry
    for lc_entry in "${lc_version_entries[@]}"; do
        ### Extract channel prefix and version using regex
        if [[ "$lc_entry" =~ ^([a-z]+-)?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            lc_prefix="${BASH_REMATCH[1]}"  # Capture channel prefix (e.g., stable-, eus-)
            lc_version="${BASH_REMATCH[2]}" # Capture version (e.g., 4.17.9)    
            ### 1. Determine the channel
            if [[ -n "$lc_prefix" ]]; then
                lc_channel="${lc_prefix}${lc_version%.*}"  # e.g., stable-4.17, eus-4.18
            else
                lc_channel="${lc_default_channel_prefix}-${lc_version%.*}"  # e.g., stable-4.17
            fi
            ### 2. Store OCP version in temporary array
            temp_version_array+=("$lc_version")

            ### 3. Map channel to OCP versions in temporary associative array
            if [[ -n "${temp_channel_versions[$lc_channel]}" ]]; then
                temp_channel_versions["$lc_channel"]="${temp_channel_versions[$lc_channel]} $lc_version"
            else
                temp_channel_versions["$lc_channel"]="$lc_version"
            fi

            ### 4. Extract unique major-minor version into temporary local array
            lc_mm_version="${lc_version%.*}"  # Remove patch version (e.g., 4.17 from 4.17.9)
            temp_unique_mm_versions["$lc_mm_version"]=1
        fi
    done

    ### Process OCP_VERSION_ARRAY: uniq and sort -V
    mapfile -t OCP_VERSION_ARRAY < <(printf '%s\n' "${temp_version_array[@]}" | sort -V | uniq)

    ### Process CHANNEL_TO_VERSIONS: uniq and sort -V for each channel's versions
    for lc_channel in "${!temp_channel_versions[@]}"; do
        # Convert space-separated versions to sorted and unique list
        mapfile -t sorted_versions < <(echo "${temp_channel_versions[$lc_channel]}" | tr ' ' '\n' | sort -V | uniq)
        CHANNEL_TO_VERSIONS["$lc_channel"]="${sorted_versions[*]}"
    done

    ### Convert unique major-minor versions to global array with sort -V
    mapfile -t MAJOR_MINOR_ARRAY < <(printf '%s\n' "${!temp_unique_mm_versions[@]}" | sort -V)

    ### Clean up temporary variables
    unset temp_unique_mm_versions
    unset temp_channel_versions
    unset temp_version_array
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