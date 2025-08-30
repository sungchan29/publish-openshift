#!/bin/bash

### OpenShift Version
OCP_VERSION="4.19.9"

### Cluster Name and Domain
CLUSTER_NAME="hub"
CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"

OSUS_POLICY_ENGINE_GRAPH_URI=""


### Tool Paths
TOOLS_BASE_DIR="/root/ocp4/download/4.19.9/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"
BUTANE_FILE="${TOOLS_BASE_DIR}/butane"


###
### Certificates
###
CERT_FILES_BASE_DIR="$PWD/custom-certs"
###
###  Ingress TLS and Custom CA Configuration
CUSTOM_ROOT_CA_FILE="$CERT_FILES_BASE_DIR/rootCA/rootCA.crt"
INGRESS_CUSTOM_TLS_KEY_FILE="$CERT_FILES_BASE_DIR/domain_certs/wildcard.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.key"
INGRESS_CUSTOM_TLS_CRT_FILE="$CERT_FILES_BASE_DIR/domain_certs/wildcard.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.crt"
###
### Default : $CUSTOM_ROOT_CA_FILE
CLUSTER_OSUS_CRT_FILE=""
MIRROR_REGISTRY_CRT_FILE=""

### Mirror Registry
PULL_SECRET="./pull-secret"
MIRROR_REGISTRY_HOSTNAME="registry.hub.tistory.disconnected"
MIRROR_REGISTRY_PORT="5000"
MIRROR_REGISTRY_USERNAME="admin"
MIRROR_REGISTRY_PASSWORD="redhat1!"
LOCAL_REPOSITORY_NAME="ocp4/openshift"

### Operator Catalog Sources
#OLM_OPERATORS="redhat--certified"
OLM_OPERATORS="redhat"
IDMS_OLM_CERTIFIED=""
IDMS_OLM_COMMUNITY=""

### SSH Keys
SSH_KEY_01="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINjb2OTBAVqUt7aMpxbUNBqyZsHxqEoFFOwWU3TKeW9H"
SSH_KEY_02="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC9i9mgVZGB4wPXAEeGCDvLflvhDJy8WWyrtLQSC5yLa"

### Node Information
###   Node info : role--hostname--<Interface info 1>[--<Interface info 2>][...][--<Interface info $NODE_INTERFACE_MAX_NUM>]
###   Interface info : <interface_name--mac_address--ip_address--prefix_length--destination--next_hop_address(gateway)--table_id>
NODE_INFO_LIST=(
    "master--sno--enp1s0--10:54:00:7d:e1:10--11.119.120.100--24--0.0.0.0/0--11.119.120.28--254"
)
NODE_INFO_LIST=(
    "master--mst01--enp1s0--10:54:00:7d:e1:11--11.119.120.111--24--0.0.0.0/0--11.119.120.28--254"
    "master--mst02--enp1s0--10:54:00:7d:e1:12--11.119.120.112--24--0.0.0.0/0--11.119.120.28--254"
    "master--mst03--enp1s0--10:54:00:7d:e1:13--11.119.120.113--24--0.0.0.0/0--11.119.120.28--254"
    "worker--ifr01--enp1s0--10:54:00:7d:e1:21--11.119.120.121--24--0.0.0.0/0--11.119.120.28--254"
    "worker--ifr02--enp1s0--10:54:00:7d:e1:22--11.119.120.122--24--0.0.0.0/0--11.119.120.28--254"
)

### Network Configuration
NTP_SERVER_01="11.119.120.28"
NTP_SERVER_02=""
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

### The rendezvousIP must be assigned to a host with the master role.
RENDEZVOUS_IP="11.119.120.111"

### Disk Configuration
#ROOT_DEVICE_NAME="/dev/disk/by-path/pci-0000:04:00.0"
ROOT_DEVICE_NAME="/dev/vda"
ADD_DEVICE_NAME=""

FILESYSTEM_PATH="/var/lib/containers"
ADD_DEVICE_TYPE=""                   # "DIRECT" or "PARTITION"
ADD_DEVICE_PARTITION_START_MIB=""    # If ROOT_DEVICE_NAME equals ADD_DEVICE_NAME, set to 25000 MiB (starts partition at 25GB for /var/lib/containers, typically partition 5).

### Network Configuration
###  Red Hat OpenShift Network Calculator: https://access.redhat.com/labs/ocpnc/
MACHINE_NETWORK="11.119.120.0/24"
SERVICE_NETWORK="10.1.0.0/21"
CLUSTER_NETWORK_CIDR="10.0.0.0/21"
HOST_PREFIX="24"

### ovnKubernetesConfig
INTERNAL_JOIN_SUBNET=""
INTERNAL_TRANSIT_SWITCH_SUBNET=""
INTERNAL_MASQUERADE_SUBNET=""

### Directory Setup
CUSTOM_CONFIG_DIR="$PWD/$CLUSTER_NAME/orig/custom_config"
VULNERABILITY_MITIGATION_DIR="$PWD/$CLUSTER_NAME/orig/vulnerability-mitigation"
BUTANE_BU_DIR="$PWD/$CLUSTER_NAME/orig/bu"
ADDITIONAL_MANIFEST="$PWD/$CLUSTER_NAME/orig/openshift"

###
### This section defines functions for validating configuration values used in the agent-based installation
###   or sets default values for variables that are empty.
###
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "[ERROR] File '$file' does not exist."
        exit 1
    fi
}

validate_non_empty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        echo "[ERROR] Variable '$var_name' is empty."
        exit 1
    fi
}

### Validate Input Parameters
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN"  "$BASE_DOMAIN"

### File System Configuration
ADD_DEVICE_TYPE="${ADD_DEVICE_TYPE:-"DIRECT"}"
if [[ "$ADD_DEVICE_TYPE" != "DIRECT" && "$ADD_DEVICE_TYPE" != "PARTITION" ]]; then
    echo "[ERROR] Invalid ADD_DEVICE_TYPE: '$ADD_DEVICE_TYPE'. Must be 'DIRECT' or 'PARTITION'."
    exit 1
fi
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

### Mirror Registry Setup
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

    ### Check if pull secret exists and matches
    should_write=1
    message="[INFO] Created pull secret at '$PULL_SECRET'"
    if [[ -f "$PULL_SECRET" ]]; then
        if command -v jq >/dev/null 2>&1; then
            existing_auth=$(jq -r ".auths.\"${MIRROR_REGISTRY}\".auth // \"\"" "$PULL_SECRET" 2>/dev/null || echo "")
            if [[ "$existing_auth" == "$auth_encoding" ]]; then
                should_write=0
            else
                echo "[WARN] Pull secret '$PULL_SECRET' exists but does not match '$MIRROR_REGISTRY'."
            fi
        else
            echo "[WARN] jq not found. Cannot verify pull secret content."
        fi
    fi

    ### Write pull secret if needed
    if [[ $should_write -eq 1 ]]; then
        echo "$pull_secret" > "$PULL_SECRET" || {
            echo "[ERROR] Failed to write pull secret to '$PULL_SECRET'."
            exit 1
        }
    fi

    echo ""
fi