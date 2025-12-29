#!/bin/bash

### ---------------------------------------------------------------------------------
### Disconnected OCP Installation :: Configuration Script
### Image Mirroring Configuration and Utilities
### ---------------------------------------------------------------------------------
### This script defines variables, paths, and helper functions for mirroring OpenShift assets.
### It is intended to be sourced by other scripts to provide configuration.

### ---------------------------------------------------------------------------------
### 1. Pull Secret Configuration
### ---------------------------------------------------------------------------------
### Specifies the path to the pull secret file (JSON format) required for registry authentication.
PULL_SECRET_FILE="$PWD/pull-secret.txt"

### ---------------------------------------------------------------------------------
### 2. OpenShift Version Configuration
### ---------------------------------------------------------------------------------
### Defines the OpenShift versions to be mirrored.
### Format: [channel-]<major.minor.patch> (e.g., "stable-4.20.4--4.19.10")
### Separator: '--'
### If no channel prefix is provided, 'stable' is assumed.

OCP_VERSIONS="4.20.6"

### ---------------------------------------------------------------------------------
### 3. Additional Container Images
### ---------------------------------------------------------------------------------
### Define all additional tool images in this array.
ADDITIONAL_TOOLS_IMAGES=(
    "registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4"
    "registry.redhat.io/rhel9/support-tools:latest"
    ### Add images
    ""
)

### ---------------------------------------------------------------------------------
### 4. Client Tool Download Configuration
### ---------------------------------------------------------------------------------
### Identifies the highest version provided to determine which client version to download.
### Logic: Replaces '--' with newline, removes channel prefix, sorts purely by version numbers.
OCP_TARGET_VERSION=$(echo "$OCP_VERSIONS" | sed 's/--/\n/g' | sed 's/.*-//' | sort -Vr | head -n 1)

### Defines URLs and filenames for the OpenShift command-line clients (oc, kubectl).
OPENSHIFT_CLIENT_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_TARGET_VERSION}"
OPENSHIFT_CLIENT_RHEL8_TAR="openshift-client-linux-amd64-rhel8.tar.gz"
OPENSHIFT_CLIENT_RHEL9_TAR="openshift-client-linux-amd64-rhel9.tar.gz"

### ---------------------------------------------------------------------------------
### 5. oc-mirror Tool Download Configuration
### ---------------------------------------------------------------------------------
### Defines URLs and filenames for the 'oc-mirror' plugin.
OC_MIRROR_DOWNLOAD_URL="${OPENSHIFT_CLIENT_DOWNLOAD_URL}"
OC_MIRROR_RHEL8_TAR="oc-mirror.tar.gz"
OC_MIRROR_RHEL9_TAR="oc-mirror.rhel9.tar.gz"

### ---------------------------------------------------------------------------------
### 6. Helper Tools Download Configuration (Butane, Pipelines, & yq)
### ---------------------------------------------------------------------------------
### Defines the URL for the Butane binary (Ignition config generator).
BUTANE_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane"

### Defines the URL for the Pipelines CLI binary (tkn).
PIPELINES_CLI_DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/pipelines/1.19.0/tkn-linux-amd64.tar.gz"

### Defines the URL for the yq binary (YAML processor).
### Note: Using 'latest' version. Pin a specific version (e.g., /v4.40.5/yq_linux_amd64) if needed for stability.
YQ_DOWNLOAD_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"

### ---------------------------------------------------------------------------------
### 7. OSUS
### ---------------------------------------------------------------------------------
### Generates a Dockerfile to pull Cincinnati graph data (Advanced/Optional use).
### https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index#update-service-graph-data_updating-disconnected-cluster-osus
create_dockerfile() {
    cat << EOF > ./Dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN curl -k -L -o cincinnati-graph-data.tar.gz https://api.openshift.com/api/upgrades_info/graph-data
RUN mkdir -p /var/lib/cincinnati-graph-data && tar xvzf cincinnati-graph-data.tar.gz -C /var/lib/cincinnati-graph-data/ --no-overwrite-dir --no-same-owner
CMD ["/bin/bash", "-c", "exec cp -rp /var/lib/cincinnati-graph-data/* /var/lib/cincinnati/graph-data"]
EOF
}

### ---------------------------------------------------------------------------------
### 8. Operator Lifecycle Manager (OLM) Configuration
### ---------------------------------------------------------------------------------
### Specifies operator catalog sources to mirror (e.g., "redhat", "certified").
###   Separator: '--'
###   Default: "redhat"
OLM_CATALOGS="redhat--certified"

### Controls OLM index image mirroring.
### Default: "true". Set to "false" for testing or to skip index mirroring.
PULL_OLM_INDEX_IMAGE=""

### ---------------------------------------------------------------------------------
### 9. Operators to Mirror
### ---------------------------------------------------------------------------------
### Defines the list of Red Hat operators to mirror.
### Format: "OPERATOR_NAME[|VERSION_1|VERSION_2|...]"
### Examples:
###   REDHAT_OPERATORS=(
###     "cluster-logging"
###     "openshift-gitops-operator|openshift-gitops-operator.v1.4.2|openshift-gitops-operator.v1.14.2|openshift-gitops-operator.v1.13.5|openshift-gitops-operator.v1.15.0|openshift-gitops-operator.v1.6.6"
###   )
###
### Tip: You can find the CSV names of currently installed operators with this command:
###   oc get csv -A | awk '{print $2}' | egrep -v "packageserver|NAME" | sort | uniq
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

### Defines the list of Certified operators to mirror.
CERTIFIED_OPERATORS=(
    "elasticsearch-eck-operator-certified"
)

### Defines the list of Community operators to mirror.
COMMUNITY_OPERATORS=(
    ""
)

### OLM Catalog Filenames
### Defines the list of possible filenames for operator catalog metadata.
### The script will search for these files in order.
CATALOG_FILENAMES=(
    "catalog.yaml"
    "catalog.json"
    "index.json"
    "channel.json"
    "channel-stable.json"
    "channels.json"
    "package.json"
    "bundles.json"
)

### ---------------------------------------------------------------------------------
### 10. Directory & Execution Settings (Defaults)
### ---------------------------------------------------------------------------------
### These variables serve as defaults and can be overridden if specific paths are required.
### Note: Actual values are computed in the INTERNAL LOGIC section if left empty.

### Base working directory for all mirrored assets.
### Default: $(realpath "$PWD")/$OCP_VERSIONS
WORK_DIR=""

### Directory for storing downloaded binaries.
###   Default: $WORK_DIR/export/tool-binaries
TOOL_DIR=""

### Cache directory for 'oc-mirror' layers.
###   Default: $PWD
OC_MIRROR_CACHE_DIR=""

### Directory for additional tool images.
###   Default: $WORK_DIR/export/additional-images
OCP_TOOL_IMAGE_DIR=""

### Execution parameters for 'oc-mirror'.
###   Default:
###     OC_MIRROR_LOG_LEVEL: "info"
###     OC_MIRROR_IMAGE_TIMEOUT: "60m0s"
###     OC_MIRROR_RETRY_TIMES: "7"
OC_MIRROR_LOG_LEVEL=""
OC_MIRROR_IMAGE_TIMEOUT=""
OC_MIRROR_RETRY_TIMES=""

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### Validate OCP_VERSIONS
OCP_VERSIONS="${OCP_VERSIONS:-"$1"}"
if [[ -z "${OCP_VERSIONS}" ]]; then
    log_error "OCP_VERSIONS is not set."
    exit 1
fi

### Set Default Values
OLM_CATALOGS="${OLM_CATALOGS:-"redhat"}"
PULL_OLM_INDEX_IMAGE="${PULL_OLM_INDEX_IMAGE:-"true"}"

OC_MIRROR_LOG_LEVEL="${OC_MIRROR_LOG_LEVEL:-"info"}"
OC_MIRROR_IMAGE_TIMEOUT="${OC_MIRROR_IMAGE_TIMEOUT:-"60m0s"}"
OC_MIRROR_RETRY_TIMES="${OC_MIRROR_RETRY_TIMES:-7}"

WORK_DIR="${WORK_DIR:-"$(realpath "$PWD")/$OCP_VERSIONS"}"
TOOL_DIR="${TOOL_DIR:-"$WORK_DIR/export/tool-binaries"}"
OC_MIRROR_CACHE_DIR="${OC_MIRROR_CACHE_DIR:-"$PWD"}"
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

### Validation Helper Function
validate_non_empty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Required variable '$var_name' is not set. Exiting..."
        exit 1
    fi
}

### Setup Logging Directory
log_dir="$WORK_DIR/logs"
if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" || {
        printf "%-8s%-80s\n" "[ERROR]" "Failed to create log directory '$log_dir'."
        exit 1
    }
fi

### Version Extraction Logic
declare -a OCP_VERSION_ARRAY
declare -A CHANNEL_TO_VERSIONS
declare -a MAJOR_MINOR_ARRAY

extract_ocp_versions() {
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

            ### Default to stable if no prefix
            if [[ -n "$lc_prefix" ]]; then
                lc_channel="${lc_prefix}${lc_version%.*}"
            else
                lc_channel="${lc_default_channel_prefix}-${lc_version%.*}"
            fi

            temp_version_array+=("$lc_version")

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
        printf "%-8s%-80s\n" "[ERROR]" "No valid versions found. Exiting..."
        exit 1
    fi

    mapfile -t OCP_VERSION_ARRAY < <(printf '%s\n' "${temp_version_array[@]}" | sort -V | uniq)

    for lc_channel in "${!temp_channel_versions[@]}"; do
        mapfile -t sorted_versions < <(echo "${temp_channel_versions[$lc_channel]}" | tr ' ' '\n' | sort -V | uniq)
        CHANNEL_TO_VERSIONS["$lc_channel"]="${sorted_versions[*]}"
    done

    mapfile -t MAJOR_MINOR_ARRAY < <(printf '%s\n' "${!temp_unique_mm_versions[@]}" | sort -V)

    printf "%-8s%-80s\n" "[INFO]" "    Found OCP full versions: ${OCP_VERSION_ARRAY[*]}"
    printf "%-8s%-80s\n" "[INFO]" "    Found OCP channel mappings: $(for key in "${!CHANNEL_TO_VERSIONS[@]}"; do echo "$key=[${CHANNEL_TO_VERSIONS[$key]}]"; done | tr '\n' ' ')"
    printf "%-8s%-80s\n" "[INFO]" "    Found OCP major.minor versions: ${MAJOR_MINOR_ARRAY[*]}"
}

### Helper: Get Channel by Version
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

### Environment Validation
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Pull secret not found at: $PULL_SECRET_FILE"
    exit 1
fi

if ! command -v jq >/dev/null; then
    printf "%-8s%-80s\n" "[ERROR]" "'jq' command is required but not installed."
    exit 1
fi