#!/bin/bash

### ---------------------------------------------------------------------------------
### OpenShift Cluster Configuration
### ---------------------------------------------------------------------------------
### This script defines all necessary parameters for generating OpenShift installation manifests.

### ---------------------------------------------------------------------------------
### Cluster Definition
### ---------------------------------------------------------------------------------
### Specifies the OpenShift version for the installation.
OCP_VERSION="4.20.0"

### Defines the cluster's name and base domain.
### These are combined to form the cluster's FQDN (e.g., cloudpang.cloudpang.lan).
CLUSTER_NAME="ocp4-hub"
BASE_DOMAIN="cloudpang.lan"

### Configures the OpenShift Update Service (OSUS).
### If using a local graph URI, specify it here.
### Leave empty to use the default Red Hat update service.
OSUS_POLICY_ENGINE_GRAPH_URI=""

### ---------------------------------------------------------------------------------
### Tooling and Binary Paths
### ---------------------------------------------------------------------------------
### Defines the base directory where installation tools are stored.
TOOLS_BASE_DIR="/root/ocp4/download/4.19.15/export/tool-binaries"

### Specifies the full paths to the OpenShift client and Butane binaries.
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"
BUTANE_FILE="${TOOLS_BASE_DIR}/butane"

### ---------------------------------------------------------------------------------
### Certificate Management
### ---------------------------------------------------------------------------------
### Defines the base directory for custom certificate files.
CERT_FILES_BASE_DIR="$PWD/custom-certs"

### Defines paths for the custom root CA and the ingress wildcard certificate/key files.
CUSTOM_ROOT_CA_FILE="$CERT_FILES_BASE_DIR/rootCA/rootCA.crt"
INGRESS_CUSTOM_TLS_KEY_FILE="$CERT_FILES_BASE_DIR/domain_certs/wildcard.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.key"
INGRESS_CUSTOM_TLS_CRT_FILE="$CERT_FILES_BASE_DIR/domain_certs/wildcard.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.crt"

### Specifies certificate files for OSUS and the mirror registry.
### These default to the custom root CA if not set explicitly.
CLUSTER_OSUS_CRT_FILE=""
MIRROR_REGISTRY_CRT_FILE=""

### ---------------------------------------------------------------------------------
### Mirror Registry
### ---------------------------------------------------------------------------------
### Specifies the path to the pull secret file.
### If this file does not exist, it will be automatically generated using the variables below.
PULL_SECRET="./pull-secret"

### Defines the connection details for the local mirror registry.
MIRROR_REGISTRY_HOSTNAME="registry.cloudpang.lan"
MIRROR_REGISTRY_PORT="5000"
MIRROR_REGISTRY_USERNAME="admin"
MIRROR_REGISTRY_PASSWORD="redhat1!"
LOCAL_REPOSITORY_NAME="ocp4/openshift"

### ---------------------------------------------------------------------------------
### Operator Lifecycle Manager (OLM)
### ---------------------------------------------------------------------------------
### Defines the operator catalog sources to install, separated by '--'.
### Available options: "redhat", "certified", "community".
OLM_OPERATORS="redhat--certified"

### Specifies the file path for each operator catalog's ImageDigestMirrorSet (IDMS) YAML.
### This path is where the 'oc-mirror' command stores the IDMS configuration.
### NOTE: The path MUST be set for "certified" and "community" if they are enabled.

### Set this path for the Red Hat catalog ONLY when using mirrored files.
IDMS_OLM_REDHAT=""
### Path to the IDMS file for the Certified catalog (required if enabled).
IDMS_OLM_CERTIFIED="/root/ocp4/download/4.19.15/export/oc-mirror/olm/certified/4.19/working-dir/cluster-resources/idms-oc-mirror.yaml"
### Path to the IDMS file for the Community catalog (required if enabled).
IDMS_OLM_COMMUNITY=""

### ---------------------------------------------------------------------------------
### SSH and Node Configuration
### ---------------------------------------------------------------------------------
### Defines the SSH public keys for accessing cluster nodes.
SSH_KEY_01="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINjb2OTBAVqUt7aMpxbUNBqyZsHxqEoFFOwWU3TKeW9H"
SSH_KEY_02="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC9i9mgVZGB4wPXAEeGCDvLflvhDJy8WWyrtLQSC5yLa"

### Defines the cluster nodes and their network interfaces.
### Format for each entry:
###   role--hostname--<Interface 1>[--<Interface 2>]...
### Format for each interface:
###   interface_name--mac_address--ip_address--prefix--destination--gateway--table_id
NODE_INFO_LIST=(
    "master--mst01--enp1s0--10:54:00:7d:e1:11--11.119.120.111--24--0.0.0.0/0--11.119.120.28--254"
    "master--mst02--enp1s0--10:54:00:7d:e1:12--11.119.120.112--24--0.0.0.0/0--11.119.120.28--254"
    "master--mst03--enp1s0--10:54:00:7d:e1:13--11.119.120.113--24--0.0.0.0/0--11.119.120.28--254"
    "worker--ifr01--enp1s0--10:54:00:7d:e1:21--11.119.120.121--24--0.0.0.0/0--11.119.120.28--254"
    "worker--ifr02--enp1s0--10:54:00:7d:e1:22--11.119.120.122--24--0.0.0.0/0--11.119.120.28--254"
)
NODE_INFO_LIST=(
    "master--sno--enp1s0--10:54:00:7d:e1:11--11.119.120.100--24--0.0.0.0/0--11.119.120.28--254"
)

### ---------------------------------------------------------------------------------
### Network Configuration
### ---------------------------------------------------------------------------------
### Defines NTP and DNS server addresses.
NTP_SERVER_01="11.119.120.28"
NTP_SERVER_02=""
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

### The 'rendezvousIP' must be the IP address of one of the master nodes.
RENDEZVOUS_IP="11.119.120.111"
RENDEZVOUS_IP="11.119.120.100"

### Defines the network CIDRs for the cluster.
### See: https://access.redhat.com/labs/ocpnc/
MACHINE_NETWORK="11.119.120.0/24"
SERVICE_NETWORK="10.1.0.0/21"
CLUSTER_NETWORK_CIDR="10.0.0.0/21"
HOST_PREFIX="24"

### Optional 'ovnKubernetesConfig' settings.
INTERNAL_JOIN_SUBNET=""
INTERNAL_TRANSIT_SWITCH_SUBNET=""
INTERNAL_MASQUERADE_SUBNET=""

### ---------------------------------------------------------------------------------
### Disk Configuration
### ---------------------------------------------------------------------------------
### Defines the root device for the cluster nodes (e.g., "/dev/vda").
ROOT_DEVICE_NAME="/dev/vda"

### Defines an additional device for the container filesystem (optional).
ADD_DEVICE_NAME=""
FILESYSTEM_PATH="/var/lib/containers"

### Defines the type of the additional device.
### Options: "DIRECT" (entire device) or "PARTITION" (a specific partition).
ADD_DEVICE_TYPE=""
### Defines partition start offset in MiB (only if ADD_DEVICE_TYPE="PARTITION").
ADD_DEVICE_PARTITION_START_MIB=""

### ---------------------------------------------------------------------------------
### Directory Structure
### ---------------------------------------------------------------------------------
### Defines the output directories for generated configuration files and manifests.
CUSTOM_CONFIG_DIR="$PWD/$CLUSTER_NAME/orig/custom_config"
VULNERABILITY_MITIGATION_DIR="$PWD/$CLUSTER_NAME/orig/vulnerability-mitigation"
BUTANE_BU_DIR="$PWD/$CLUSTER_NAME/orig/bu"
ADDITIONAL_MANIFEST="$PWD/$CLUSTER_NAME/orig/openshift"


######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### ---------------------------------------------------------------------------------
### Validation and Default Value Functions
### ---------------------------------------------------------------------------------
### The following functions validate user inputs and set default values.

### Checks if a specified file exists.
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "    Required file not found: '$file'. Exiting..."
        exit 1
    fi
}

### Checks if a variable has a non-empty value.
validate_non_empty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Required variable '$var_name' is not set. Exiting..."
        exit 1
    fi
}

### Validate essential cluster parameters.
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN"  "$BASE_DOMAIN"

### Set file system configuration defaults and validate inputs.
ADD_DEVICE_TYPE="${ADD_DEVICE_TYPE:-"DIRECT"}"
if [[ "$ADD_DEVICE_TYPE" != "DIRECT" && "$ADD_DEVICE_TYPE" != "PARTITION" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Invalid ADD_DEVICE_TYPE: '$ADD_DEVICE_TYPE'. Must be 'DIRECT' or 'PARTITION'. Exiting..."
    exit 1
fi
### Automatically configure partition settings based on device names and type.
if [[ "$ROOT_DEVICE_NAME" = "$ADD_DEVICE_NAME" ]]; then
    ADD_DEVICE_TYPE="PARTITION"
    PARTITION_START_MIB="${ADD_DEVICE_PARTITION_START_MIB:-25000}"
    PARTITION_SIZE_MIB="0"
    PARTITION_NUMBER="5"
else
    if [[ "$ADD_DEVICE_TYPE" = "PARTITION" ]]; then
        PARTITION_START_MIB="0"
        PARTITION_SIZE_MIB="0"
        PARTITION_NUMBER="1"
    fi
fi
FILESYSTEM_PATH="${FILESYSTEM_PATH:-/var/lib/containers}"
PARTITION_LABEL="${PARTITION_LABEL:-$(echo "$FILESYSTEM_PATH" | sed 's#^/##; s#/#-#g')}"

### Validate certificate files and automatically generate the pull secret if needed.
if [[ -n "$CUSTOM_ROOT_CA_FILE" ]]; then
    validate_file "$CUSTOM_ROOT_CA_FILE"
fi

MIRROR_REGISTRY="${MIRROR_REGISTRY_HOSTNAME}:${MIRROR_REGISTRY_PORT}"
MIRROR_REGISTRY_CRT_FILE="${MIRROR_REGISTRY_CRT_FILE:-$CUSTOM_ROOT_CA_FILE}"
if [[ -f "$MIRROR_REGISTRY_CRT_FILE" ]]; then
    validate_non_empty "MIRROR_REGISTRY"          "$MIRROR_REGISTRY"
    validate_non_empty "MIRROR_REGISTRY_USERNAME" "$MIRROR_REGISTRY_USERNAME"
    validate_non_empty "MIRROR_REGISTRY_PASSWORD" "$MIRROR_REGISTRY_PASSWORD"

    auth_info="${MIRROR_REGISTRY_USERNAME}:${MIRROR_REGISTRY_PASSWORD}"
    auth_encoding=$(echo -n "$auth_info" | base64 -w0)
    pull_secret="{\"auths\":{\"${MIRROR_REGISTRY}\":{\"auth\":\"${auth_encoding}\"}}}"

    ### Check if pull secret file exists and if its content needs updating.
    should_write=1
    if [[ -f "$PULL_SECRET" ]]; then
        if command -v jq >/dev/null 2>&1; then
            existing_auth=$(jq -r ".auths.\"${MIRROR_REGISTRY}\".auth // \"\"" "$PULL_SECRET" 2>/dev/null || true)
            if [[ "$existing_auth" == "$auth_encoding" ]]; then
                should_write=0
            else
                printf "%-8s%-80s\n" "[WARN]" "    Existing pull secret at '$PULL_SECRET' has different credentials for '$MIRROR_REGISTRY'. It will be overwritten."
            fi
        else
            printf "%-8s%-80s\n" "[WARN]" "    'jq' command not found. Cannot verify content of existing pull secret. It will be overwritten to be safe."
        fi
    fi

    ### Write the pull secret file if it needs to be created or updated.
    if [[ $should_write -eq 1 ]]; then
        echo "$pull_secret" > "$PULL_SECRET" || {
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to write pull secret to '$PULL_SECRET'. Check permissions. Exiting..."
            exit 1
        }
    fi
fi