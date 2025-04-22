#!/bin/bash

### OpenShift Version
OCP_VERSION="4.17.23"

### Tool Paths
TOOLS_BASE_DIR="/root/sungchan-desk/ocp4/disconnected/4.17.23--4.18.7/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"
BUTANE_FILE="${TOOLS_BASE_DIR}/butane"

### Certificates
CUSTOM_ROOT_CA="/root/sungchan-desk/ocp4/disconnected/rootCA/rootCA.crt"
CLUSTER_TLS_KEY="/root/sungchan-desk/ocp4/disconnected/domain_certs/wildcard.apps.cloudpang.tistory.disconnected.key"
CLUSTER_TLS_CERT="/root/sungchan-desk/ocp4/disconnected/domain_certs/wildcard.apps.cloudpang.tistory.disconnected.crt"

### Mirror Registry
PULL_SECRET="./pull-secret"
MIRROR_REGISTRY_TRUST_FILE="$CUSTOM_ROOT_CA"
MIRROR_REGISTRY_HOSTNAME="nexus.cloudpang.tistory.disconnected"
MIRROR_REGISTRY_PORT="5000"
MIRROR_REGISTRY_USERNAME="admin"
MIRROR_REGISTRY_PASSWORD="redhat1!"
LOCAL_REPOSITORY_NAME="ocp4/openshift"

### Operator Catalog Sources
OLM_OPERATORS="redhat--certified"
IDMS_OLM_CERTIFIED=""
IDMS_OLM_COMMUNITY=""

### Cluster Configuration
CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"
SSH_KEY_01="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG8qJQJbNWHxvHOMOgtA++F2TdtvYEvrBEWPHkvKg+is root@thinkpad"
SSH_KEY_02="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINw0niln0q4xQVALeSuwjfMvPN4chTNYgHMPVOGgJqfw root@thinkstation"

### Agent Configuration
NTP_SERVER_01="11.119.120.28"
NTP_SERVER_02=""
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""
RENDEZVOUS_IP="11.119.120.111"

### Node Information
NODE_INFO_LIST=(
    "master--sno--enp1s0--52:54:00:7d:e1:09--11.119.120.109--24--0.0.0.0/0--11.119.120.28--254"
)
NODE_INFO_LIST=(
    "master--master01--enp1s0--52:54:00:7d:e1:11--11.119.120.111--24--0.0.0.0/0--11.119.120.28--254"
    "master--master02--enp1s0--52:54:00:7d:e1:12--11.119.120.112--24--0.0.0.0/0--11.119.120.28--254"
    "master--master03--enp1s0--52:54:00:7d:e1:13--11.119.120.113--24--0.0.0.0/0--11.119.120.28--254"
    "worker--infra01--enp1s0--52:54:00:7d:e1:21--11.119.120.121--24--0.0.0.0/0--11.119.120.28--254"
    "worker--infra02--enp1s0--52:54:00:7d:e1:22--11.119.120.122--24--0.0.0.0/0--11.119.120.28--254"
    "worker--worker01--enp1s0--52:54:00:7d:e1:24--11.119.120.124--24--0.0.0.0/0--11.119.120.28--254"
)

NODE_INTERFACE_MAX_NUM=3

### MachineConfigPool
NODE_ROLE_SELECTORS="infra--infra01|infra02"

### Ingress Configuration
INGRESS_REPLICAS=2
INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY="node-role.kubernetes.io/infra"
CONFIGMAP_INGRESS_CUSTOM_ROOT_CA="ingress-custom-root-ca"
SECRET_INGRESS_CUSTOM_TLS="ingress-custom-default"
INGRESS_CUSTOM_ROOT_CA="$CUSTOM_ROOT_CA"
INGRESS_CUSTOM_TLS_KEY="$CLUSTER_TLS_KEY"
INGRESS_CUSTOM_TLS_CERT="$CLUSTER_TLS_CERT"

### Disk Configuration
ROOT_DEVICE_NAME="/dev/disk/by-path/pci-0000:04:00.0"
ADD_DEVICE_NAME=""
FILESYSTEM_PATH="/var/lib/containers"
ADD_DEVICE_TYPE=""
ADD_DEVICE_PARTITION_START_MIB=""

### Network Configuration
MACHINE_NETWORK="11.119.120.0/24"
SERVICE_NETWORK="10.1.0.0/21"
CLUSTER_NETWORK_CIDR="10.0.0.0/21"
HOST_PREFIX="24"

### ovnKubernetesConfig
INTERNAL_JOIN_SUBNET=""
INTERNAL_TRANSIT_SWITCH_SUBNET=""
INTERNAL_MASQUERADE_SUBNET=""

### Installation Wait Parameters
INSTALL_COMPLETE_LOG_FILE="./wait-for_install-complete.log"
MAX_TRIES=3
TIMEOUT=7200
NODE_LABEL_TRIGGER_SEARCH_KEYWORD="cluster bootstrap is complete"
INSTALL_COMPLETE_SEARCH_KEYWORD="Cluster is installed"

### Directory Setup
CUSTOM_CONFIG_DIR="$PWD/$CLUSTER_NAME/orig/custom_config"
VULNERABILITY_MITIGATION_DIR="$PWD/$CLUSTER_NAME/orig/vulnerability-mitigation"
BUTANE_BU_DIR="$PWD/$CLUSTER_NAME/orig/bu"
ADDITIONAL_MANIFEST="$PWD/$CLUSTER_NAME/orig/openshift"

### Validation Functions
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "[ERROR] File '$file' does not exist. Exiting..."
        exit 1
    fi
}

validate_non_empty() {
    local var_name="$1"
    local var_value="$2"
    if [[ -z "$var_value" ]]; then
        echo "[ERROR] Variable '$var_name' is empty. Exiting..."
        exit 1
    fi
}

validate_ssh_key() {
    local var_name="$1"
    local value="$2"
    local context="$3"
    if ! echo "$value" | grep -qE '^ssh-(rsa|ed25519|ecdsa) [A-Za-z0-9+/=]+'; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected SSH key format, got: '$value'"
        exit 1
    fi
}

validate_role() {
    local var_name="$1"
    local value="$2"
    local context="$3"

    if [[ -z "$value" ]] || ! [[ "$value" =~ ^(master|worker)$ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected 'master' or 'worker', got: '$value'"
        exit 1
    fi
}

validate_domain() {
    local var_name="$1"
    local value="$2"
    local context="$3"

    if [[ -z "$value" ]]; then
        echo "[ERROR] $var_name is missing in context: $context"
        exit 1
    fi

    if ! echo "$value" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected domain format (RFC 1123), got: '$value'"
        exit 1
    fi
}

validate_ip_or_host_regex() {
    local ip_or_host="$1"
    if ! echo "$ip_or_host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[a-zA-Z0-9.-]+$'; then
        echo "[ERROR] Invalid IP or Hostname: '$ip_or_host'. Exiting..."
        exit 1
    fi
}

### Core IPv4 validation function
validate_ipv4() {
    local var_name="$1"
    local value="$2"
    local context="$3"
    local allow_zero="${4:-false}"

    if [[ -z "$value" ]]; then
        echo "[ERROR] $var_name is missing in context: $context"
        exit 1
    fi

    if ! [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected IPv4 format (XXX.XXX.XXX.XXX), got: '$value'"
        exit 1
    fi

    local oct1="${BASH_REMATCH[1]}"
    local oct2="${BASH_REMATCH[2]}"
    local oct3="${BASH_REMATCH[3]}"
    local oct4="${BASH_REMATCH[4]}"

    if [[ "$oct1" =~ ^0[0-9]+ || "$oct2" =~ ^0[0-9]+ || "$oct3" =~ ^0[0-9]+ || "$oct4" =~ ^0[0-9]+ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] IP octets must not have leading zeros, got: '$value'"
        exit 1
    fi

    if [[ $oct1 -gt 255 || $oct2 -gt 255 || $oct3 -gt 255 || $oct4 -gt 255 ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Each octet must be between 0 and 255, got: '$value'"
        exit 1
    fi

    if [[ ! "$allow_zero" == "true" && $oct1 -eq 0 && $oct2 -eq 0 && $oct3 -eq 0 && $oct4 -eq 0 ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] IP address 0.0.0.0 is not allowed, got: '$value'"
        exit 1
    fi
}

### CIDR validation function
validate_cidr() {
    local var_name="$1"
    local value="$2"
    local context="${3:-unknown}"

    if [[ -z "$value" ]]; then
        echo "[ERROR] $var_name is missing in context: $context"
        exit 1
    fi

    ### Allow 0.0.0.0/0
    if [[ "$value" == "0.0.0.0/0" ]]; then
        return 0
    fi

    ### Check CIDR format: XXX.XXX.XXX.XXX/XX
    if [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        local ip="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
        local mask="${BASH_REMATCH[5]}"

        ### Validate IP address
        validate_ipv4_core "$var_name" "$ip" "$context" true

        ### Validate mask (0-32)
        if [[ $mask -gt 32 ]]; then
            echo "[ERROR] Invalid $var_name in context: $context"
            echo "[ERROR] CIDR mask must be between 0 and 32, got: '$value'"
            exit 1
        fi
    else
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected CIDR format (XXX.XXX.XXX.XXX/XX or 0.0.0.0/0), got: '$value'"
        exit 1
    fi
}

validate_mac() {
    local var_name="$1"
    local value="$2"
    local context="$3"

    if [[ -z "$value" ]]; then
        echo "[ERROR] $var_name is missing in context: $context"
        exit 1
    fi

    if ! [[ "$value" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected MAC address format (XX:XX:XX:XX:XX:XX), got: '$value'"
        exit 1
    fi
}

validate_prefix() {
    local var_name="$1"
    local value="$2"
    local context="$3"

    if [[ -z "$value" ]]; then
        echo "[ERROR] $var_name is missing in context: $context"
        exit 1
    fi

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        exit 1
    fi
}

validate_table_id() {
    local var_name="$1"
    local value="$2"
    local context="$3"

    if [[ -z "$value" ]] || ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected a number, got: '$value'"
        exit 1
    fi
}

### Validate Input Parameters
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN"  "$BASE_DOMAIN"

### Disk Configuration Logic
if [[ "$ROOT_DEVICE_NAME" = "$ADD_DEVICE_NAME" ]]; then
    ADD_DEVICE_TYPE="PARTITION"
    ADD_DEVICE_PARTITION_START_MIB="${ADD_DEVICE_PARTITION_START_MIB:-25000}"
    PARTITION_SIZE_MIB="0"
    PARTITION_NUMBER="5"
elif [[ "$ADD_DEVICE_TYPE" = "PARTITION" ]]; then
    ADD_DEVICE_PARTITION_START_MIB="0"
    PARTITION_SIZE_MIB="0"
    PARTITION_NUMBER="1"
fi
FILESYSTEM_PATH="${FILESYSTEM_PATH:-/var/lib/containers}"
PARTITION_LABEL="${PARTITION_LABEL:-$(echo "$FILESYSTEM_PATH" | sed 's#^/##; s#/#-#g')}"

### Mirror Registry Setup
MIRROR_REGISTRY="${MIRROR_REGISTRY_HOSTNAME}:${MIRROR_REGISTRY_PORT}"
if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
    validate_non_empty "MIRROR_REGISTRY"          "$MIRROR_REGISTRY"
    validate_non_empty "MIRROR_REGISTRY_USERNAME" "$MIRROR_REGISTRY_USERNAME"
    validate_non_empty "MIRROR_REGISTRY_PASSWORD" "$MIRROR_REGISTRY_PASSWORD"
    if [[ -f "$PULL_SECRET" ]]; then
        echo "[WARN] Pull secret '$PULL_SECRET' exists. Overwriting..."
    fi
    auth_info="${MIRROR_REGISTRY_USERNAME}:${MIRROR_REGISTRY_PASSWORD}"
    auth_encoding=$(echo -n "$auth_info" | base64 -w0)
    pull_secret="{\"auths\":{\"${MIRROR_REGISTRY}\":{\"auth\":\"${auth_encoding}\"}}}"
    echo "$pull_secret" > "$PULL_SECRET"
    echo "[INFO] Created pull secret at '$PULL_SECRET'"
fi
