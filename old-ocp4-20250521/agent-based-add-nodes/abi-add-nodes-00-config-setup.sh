#!/bin/bash

### OpenShift Version
OCP_VERSION="4.17.25"

OCP_USER_TOKEN=""

### Node Information
###   Node info : role--hostname--<Interface info 1>[--<Interface info 2>][...][--<Interface info Max num>]
###   Interface info : <interface_name--mac_address--ip_address--prefix_length--destination--next_hop_address(gateway)--table_id>
NODE_INFO_LIST=(
    "worker--wrk01--enp1s0--10:54:00:7d:e1:31--11.119.120.131--24--0.0.0.0/0--11.119.120.28--254--enp2s0--20:54:00:7d:e1:31--29.119.120.131--24--29.119.120.0/24--29.119.120.28--254"
    "worker--wrk02--enp1s0--10:54:00:7d:e1:32--11.119.120.132--24--0.0.0.0/0--11.119.120.28--254--enp2s0--20:54:00:7d:e1:32--29.119.120.132--24--29.119.120.0/24--29.119.120.28--254"
)

CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"

### Tool Paths
TOOLS_BASE_DIR="/root/ocp4/images-download/4.17.25/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"

### Disk Configuration
#ROOT_DEVICE_NAME="/dev/disk/by-path/pci-0000:04:00.0"
ROOT_DEVICE_NAME="/dev/vda"

### Network Configuration
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

CUSTOM_ROOT_CA="/root/ocp4/certs/rootCA/rootCA.crt"

### Mirror Registry
PULL_SECRET="./pull-secret"
MIRROR_REGISTRY_TRUST_FILE="$CUSTOM_ROOT_CA"
MIRROR_REGISTRY_HOSTNAME="nexus.cloudpang.tistory.disconnected"
MIRROR_REGISTRY_PORT="5000"
MIRROR_REGISTRY_USERNAME="admin"
MIRROR_REGISTRY_PASSWORD="redhat1!"
LOCAL_REPOSITORY_NAME="ocp4/openshift"

### Approve CSRs and check node status
MAX_ATTEMPTS=30    # Maximum attempts to check node status (adjust as needed)
ATTEMPT=3
CHECK_INTERVAL=30  # Seconds between checks

###
### This section defines functions for validating configuration values used in the agent-based installation
###   or sets default values for variables that are empty.
###
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

    if ! echo "$value" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'; then
        echo "[ERROR] Invalid $var_name in context: $context"
        echo "[ERROR] Expected domain format (RFC 1123), got: '$value'"
        exit 1
    fi
}

validate_ip_or_host_regex() {
    local ip_or_host="$1"
    if ! echo "$ip_or_host" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[a-z0-9.-]+$'; then
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
        validate_ipv4 "$var_name" "$ip" "$context" true

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

### Mirror Registry Setup
MIRROR_REGISTRY="${MIRROR_REGISTRY_HOSTNAME}:${MIRROR_REGISTRY_PORT}"
if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
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
                echo "[WARN] Pull secret '$PULL_SECRET' exists but does not match '$MIRROR_REGISTRY'. Overwriting..."
            fi
        else
            echo "[WARN] jq not found. Cannot verify pull secret content. Overwriting '$PULL_SECRET'..."
        fi
    fi

    ### Write pull secret if needed
    if [[ $should_write -eq 1 ]]; then
        echo "$pull_secret" > "$PULL_SECRET" || {
            echo "[ERROR] Failed to write pull secret to '$PULL_SECRET'. Exiting..."
            exit 1
        }
    fi

    echo ""
fi
### Determine API server URL
API_SERVER="https://api.$CLUSTER_NAME.$BASE_DOMAIN:6443"

### OpenShift cluster login
login_to_cluster() {
    echo "[INFO] Attempting to log in to OpenShift cluster at $API_SERVER"

    if [[ -n "$OCP_USER_TOKEN" ]]; then
        echo "[INFO] Using OCP_USER_TOKEN for authentication"
        ./oc login "$API_SERVER" --token="$OCP_USER_TOKEN" --insecure-skip-tls-verify >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "[ERROR] Failed to log in with OCP_USER_TOKEN. Check token validity or API server reachability."
            exit 1
        fi
    else
        echo "[INFO] OCP_USER_TOKEN not provided. Prompting for username and password."
        read -p "Enter OpenShift username: " username
        read -s -p "Enter OpenShift password: " password
        echo
        validate_non_empty "username" "$username"
        validate_non_empty "password" "$password"
        ./oc login "$API_SERVER" --username="$username" --password="$password" --insecure-skip-tls-verify >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo "[ERROR] Failed to log in with username/password. Check credentials or API server reachability."
            exit 1
        fi
    fi

    ### Verify login
    if ! ./oc whoami >/dev/null 2>&1; then
        echo "[ERROR] Login verification failed. Unable to authenticate to cluster."
        exit 1
    fi
    echo "[INFO] Successfully logged in to cluster as $(./oc whoami)"
}