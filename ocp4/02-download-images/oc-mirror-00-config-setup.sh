#!/bin/bash

### ---------------------------------------------------------------------------------
### Disconnected OCP Installation :: Configuration Script
### Image Mirroring Configuration and Utilities
### ---------------------------------------------------------------------------------
### This script defines variables, paths, and helper functions for mirroring OpenShift assets. It is not intended to be executed directly
### but should be sourced by other scripts in the workflow.

### ---------------------------------------------------------------------------------
### Pull Secret
### ---------------------------------------------------------------------------------
### Specifies the path to the pull secret file (JSON format) required for
### authenticating with container registries.
PULL_SECRET_FILE="$PWD/pull-secret.txt"

### ---------------------------------------------------------------------------------
### OpenShift Versions
### ---------------------------------------------------------------------------------
### Specifies the OpenShift versions to be mirrored, separated by '--'.
### Format: [channel-]<major.minor.patch> (e.g., "stable-4.16.37--4.17.37--eus-4.18.22--4.19.10")
### If no channel prefix is provided, 'stable' is assumed.
OCP_VERSIONS="4.20.4"

### ---------------------------------------------------------------------------------
### Additional Container Images
### ---------------------------------------------------------------------------------
### Defines container images for supplementary tools and logging.
EVENTROUTER_IMAGE="registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4"
SUPPORT_TOOL_IMAGE="registry.redhat.io/rhel9/support-tools:latest"

### ---------------------------------------------------------------------------------
### Client Tool Download URLs
### ---------------------------------------------------------------------------------
### Defines URLs and filenames for the OCP command-line clients.
OCP_TARGET_VERSION=$(echo "$OCP_VERSIONS" | sed 's/--/\n/g' | sed 's/.*-//' | sort -Vr | head -n 1)
OPENSHIFT_CLIENT_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_TARGET_VERSION}"
OPENSHIFT_CLIENT_RHEL8_TAR="openshift-client-linux-amd64-rhel8.tar.gz"
OPENSHIFT_CLIENT_RHEL9_TAR="openshift-client-linux-amd64-rhel9.tar.gz"

### ---------------------------------------------------------------------------------
### OpenShift Mirror Tool
### ---------------------------------------------------------------------------------
### Defines URLs and filenames for the 'oc-mirror' tool.
OC_MIRROR_DOWNLOAD_URL="${OPENSHIFT_CLIENT_DOWNLOAD_URL}"
OC_MIRROR_RHEL8_TAR="oc-mirror.tar.gz"
OC_MIRROR_RHEL9_TAR="oc-mirror.rhel9.tar.gz"

### ---------------------------------------------------------------------------------
### Butane Tool
### ---------------------------------------------------------------------------------
### Defines the URL for the Butane binary, used for generating Ignition configs.
BUTANE_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane"

### ---------------------------------------------------------------------------------
### Pipelines CLI Tool
### ---------------------------------------------------------------------------------
### Defines the URL for the Pipelines CLI binary (tkn), used for interacting with OpenShift Pipelines.
PIPELINES_CLI_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/pipelines/1.19.0/tkn-linux-amd64.tar.gz"

### ---------------------------------------------------------------------------------
### Helper Functions
### ---------------------------------------------------------------------------------
### Generates a Dockerfile to pull Cincinnati graph data for upgrade paths.
create_dockerfile() {
    cat << EOF > ./Dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN curl -k -L -o cincinnati-graph-data.tar.gz https://api.openshift.com/api/upgrades_info/graph-data
RUN mkdir -p /var/lib/cincinnati-graph-data && tar xvzf cincinnati-graph-data.tar.gz -C /var/lib/cincinnati-graph-data/ --no-overwrite-dir --no-same-owner
CMD ["/bin/bash", "-c", "exec cp -rp /var/lib/cincinnati-graph-data/* /var/lib/cincinnati/graph-data"]
EOF
}

### ---------------------------------------------------------------------------------
### Operator Lifecycle Manager (OLM) Configuration
### ---------------------------------------------------------------------------------
### Specifies operator catalog sources to mirror (e.g., "redhat", "certified").
### Use '--' as a separator.
OLM_CATALOGS="redhat--certified"

### Flag to control OLM index image mirroring.
### Default: "true". Set to "false" for testing or to skip index mirroring.
PULL_OLM_INDEX_IMAGE=""

### ---------------------------------------------------------------------------------
### Defines the list of specific operators to mirror
### ---------------------------------------------------------------------------------
### Define the list in Bash array format. The entire list is enclosed in
### parentheses `( )`, and each element must be enclosed in double quotes `" "`.
###
### Format for each element:
###   "OPERATOR_NAME[|VERSION_1|VERSION_2|...]"
###
###   - The operator name is required.
###   - To specify particular versions, use the pipe character (|) as a delimiter.
###     You may need to use the full ClusterServiceVersion (CSV) name for the version.
###
### Default Behavior:
###   If no versions are specified, the latest version from the operator's
###   default channel will be selected automatically.
###
### Examples:
###   REDHAT_OPERATORS=(
###     "cluster-logging"
###     "openshift-gitops-operator|openshift-gitops-operator.v1.4.2|openshift-gitops-operator.v1.14.2|openshift-gitops-operator.v1.13.5|openshift-gitops-operator.v1.15.0|openshift-gitops-operator.v1.6.6"
###   )
###
### Tip: You can find the CSV names of currently installed operators with this command:
###   oc get csv -A | awk '{print $2}' | egrep -v "packageserver|NAME" | sort | uniq
### ---------------------------------------------------------------------------------
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

### List of certified operators to mirror.
CERTIFIED_OPERATORS=(
    "elasticsearch-eck-operator-certified"
)

### List of community operators to mirror.
COMMUNITY_OPERATORS=(
    ""
)

### Base working directory for all mirrored assets and generated files.
### Default: A subdirectory named after the OCP versions in the current directory.
WORK_DIR=""

### Directory for storing downloaded command-line tool binaries.
### Default: "$WORK_DIR/export/tool-binaries"
TOOL_DIR=""

### Cache directory for 'oc-mirror' to store image layers.
### Default: A '.oc-mirror-cache' directory in the current working directory.
OC_MIRROR_CACHE_DIR=""

### Directory for storing mirrored additional images.
### Default: "$WORK_DIR/export/additional-images"
OCP_TOOL_IMAGE_DIR=""

### Path to the 'oc-mirror' command to be executed.
### Default: An 'oc-mirror' binary in the current directory.
OC_MIRROR_CMD=""

### Log level for 'oc-mirror' (e.g., "debug", "info", "warn", "error").
### Default: "info"
OC_MIRROR_LOG_LEVEL=""

### Timeout for mirroring a single image.
### Default: "60m0s" (60 minutes)
OC_MIRROR_IMAGE_TIMEOUT=""

### Number of retry attempts if an image pull fails.
### Default: 7
OC_MIRROR_RETRY_TIMES=""

######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### The following sections define functions and validate variables.
### These sections should not require modification by the user.

### ---------------------------------------------------------------------------------
### Validate and Process OCP_VERSIONS
### ---------------------------------------------------------------------------------
### Sets OCP_VERSIONS from the first script argument if not already set.
### Exits if OCP_VERSIONS is still not defined.
OCP_VERSIONS="${OCP_VERSIONS:-"$1"}"
if [[ -z "${OCP_VERSIONS}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "OCP_VERSIONS is not set."
    printf "%-8s%-80s\n" "[INFO]" "Please specify OpenShift versions using '--' as a separator."
    printf "%-8s%-80s\n" "[INFO]" "Usage: $0 <OCP versions>"
    printf "%-8s%-80s\n" "[INFO]" "Example: $0 stable-4.16.37--4.17.37--4.18.22--4.19.10"
    exit 1
fi

### ---------------------------------------------------------------------------------
### Directory Configuration and Settings Variables
### ---------------------------------------------------------------------------------
### Sets default values for variables if they are not already defined.
OLM_CATALOGS="${OLM_CATALOGS:-"redhat"}"
PULL_OLM_INDEX_IMAGE="${PULL_OLM_INDEX_IMAGE:-"true"}"

OC_MIRROR_CMD="${OC_MIRROR_CMD:-"$PWD/oc-mirror"}"
OC_MIRROR_LOG_LEVEL="${OC_MIRROR_LOG_LEVEL:-"info"}"
OC_MIRROR_IMAGE_TIMEOUT="${OC_MIRROR_IMAGE_TIMEOUT:-"60m0s"}"
OC_MIRROR_RETRY_TIMES="${OC_MIRROR_RETRY_TIMES:-7}"

WORK_DIR="${WORK_DIR:-"$(realpath "$PWD")/$OCP_VERSIONS"}"
TOOL_DIR="${TOOL_DIR:-"$WORK_DIR/export/tool-binaries"}"
OC_MIRROR_CACHE_DIR="${OC_MIRROR_CACHE_DIR:-"$PWD"}"
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

### ---------------------------------------------------------------------------------
### Validation Functions
### ---------------------------------------------------------------------------------
### Checks if a variable has a non-empty value.
validate_non_empty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Required variable '$var_name' is not set. Exiting..."
        exit 1
    fi
}

### ---------------------------------------------------------------------------------
### Logging Functions
### ---------------------------------------------------------------------------------
### Creates the log directory.
log_dir="$WORK_DIR/logs"
if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" || {
        printf "%-8s%-80s\n" "[ERROR]" "Failed to create log directory '$log_dir'. Exiting..."
        exit 1
    }
fi

### Parses the OCP_VERSIONS string into structured arrays.
declare -a OCP_VERSION_ARRAY
declare -A CHANNEL_TO_VERSIONS
declare -a MAJOR_MINOR_ARRAY
extract_ocp_versions() {
    if [[ -z "$OCP_VERSIONS" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "OCP_VERSIONS is empty. Exiting..."
        exit 1
    fi
    local lc_default_channel_prefix="stable"
    local lc_prefix lc_version lc_channel lc_mm_version
    local -A temp_unique_mm_versions
    local -A temp_channel_versions
    local -a temp_version_array

    printf "%-8s%-80s\n" "[INFO]" "    Processing OCP_VERSIONS: $OCP_VERSIONS"
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
            ### Check if the key exists in the associative array.
            if [[ -v temp_channel_versions["$lc_channel"] ]]; then
                temp_channel_versions["$lc_channel"]="${temp_channel_versions[$lc_channel]} $lc_version"
            else
                temp_channel_versions["$lc_channel"]="$lc_version"
            fi
            lc_mm_version="${lc_version%.*}"
            temp_unique_mm_versions["$lc_mm_version"]=1
        else
            printf "%-8s%-80s\n" "[WARN]" "Invalid version format: '$lc_entry'. Skipping..."
        fi
    done

    if [[ ${#temp_version_array[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "No valid versions found in OCP_VERSIONS. Exiting..."
        exit 1
    fi

    mapfile -t OCP_VERSION_ARRAY < <(printf '%s\n' "${temp_version_array[@]}" | sort -V | uniq)
    for lc_channel in "${!temp_channel_versions[@]}"; do
        mapfile -t sorted_versions < <(echo "${temp_channel_versions[$lc_channel]}" | tr ' ' '\n' | sort -V | uniq)
        CHANNEL_TO_VERSIONS["$lc_channel"]="${sorted_versions[*]}"
    done
    mapfile -t MAJOR_MINOR_ARRAY < <(printf '%s\n' "${!temp_unique_mm_versions[@]}" | sort -V)

    if [[ ${#MAJOR_MINOR_ARRAY[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "MAJOR_MINOR_ARRAY is empty after processing. Exiting..."
        exit 1
    fi

    printf "%-8s%-80s\n" "[INFO]" "    Found OCP full versions: ${OCP_VERSION_ARRAY[*]}"
    printf "%-8s%-80s\n" "[INFO]" "    Found OCP channel mappings: $(for key in "${!CHANNEL_TO_VERSIONS[@]}"; do echo "$key=[${CHANNEL_TO_VERSIONS[$key]}]"; done | tr '\n' ' ')"
    printf "%-8s%-80s\n" "[INFO]" "    Found OCP major.minor versions: ${MAJOR_MINOR_ARRAY[*]}"
}

### Retrieves the channel for a specific full version string.
get_channel_by_version() {
    local input_version="$1"
    for channel in "${!CHANNEL_TO_VERSIONS[@]}"; do
        IFS=' ' read -r -a versions <<< "${CHANNEL_TO_VERSIONS[$channel]}"
        for version in "${versions[@]}"; do
            if [[ "$version" == "$input_version" ]]; then
                echo "$channel"
                return 0
            fi
        done
    done
    printf "%-8s%-80s\n" "[ERROR]" "No channel found for version '$input_version'." >&2
    return 1
}

### Validates that the pull secret file exists.
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Pull secret file '$PULL_SECRET_FILE' does not exist. Exiting..."
    exit 1
fi
### Validates that the 'jq' command is installed.
if ! command -v jq >/dev/null; then
    printf "%-8s%-80s\n" "[ERROR]" "'jq' command not found. Please install jq to validate the pull secret. Exiting..."
    exit 1
fi