#!/bin/bash

### OpenShift Version
OCP_VERSION="4.19.9"

OCP_USER_TOKEN=""

### Node Information
###   Node info : role--hostname--<Interface info 1>[--<Interface info 2>][...][--<Interface info Max num>]
###   Interface info : <interface_name--mac_address--ip_address--prefix_length--destination--next_hop_address(gateway)--table_id>
NODE_INFO_LIST=(
    "worker--wrk01--enp1s0--10:54:00:7d:e1:31--11.119.120.131--24--0.0.0.0/0--11.119.120.28--254"
    "worker--wrk02--enp1s0--10:54:00:7d:e1:32--11.119.120.132--24--0.0.0.0/0--11.119.120.28--254"
)

CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"

### Tool Paths
TOOLS_BASE_DIR="/root/ocp4/download/$OCP_VERSION/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"

### Disk Configuration
#ROOT_DEVICE_NAME="/dev/disk/by-path/pci-0000:04:00.0"
ROOT_DEVICE_NAME="/dev/vda"

### Network Configuration
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

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

### Determine API server URL
API_SERVER="https://api.$CLUSTER_NAME.$BASE_DOMAIN:6443"

### OpenShift cluster login
login_to_cluster() {
    echo "[INFO] Attempting to log in to OpenShift cluster at $API_SERVER"

    if [[ -n "$OCP_USER_TOKEN" ]]; then
        echo "[INFO] Using OCP_USER_TOKEN for authentication"
        set +e
        output=$(./oc login "$API_SERVER" --token="$OCP_USER_TOKEN" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            echo "[ERROR] Failed to log in with OCP_USER_TOKEN. Check token validity or API server reachability."
            echo "[ERROR] Details: $output"
            exit 1
        fi
    else
        ### Prompt for username and password if OCP_USER_TOKEN is not provided
        echo ""
        echo "[INFO] OCP_USER_TOKEN not provided. Prompting for username and password."
        read -p "Enter OpenShift username: " username
        read -s -p "Enter OpenShift password: " password
        echo ""
        validate_non_empty "username" "$username"
        validate_non_empty "password" "$password"

        set +e
        output=$(./oc login "$API_SERVER" --username="$username" --password="$password" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            echo "[ERROR] Failed to log in with username/password. Check credentials or API server reachability."
            echo "[ERROR] Details: $output"
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