#!/bin/bash

### ---------------------------------------------------------------------------------
### Add Worker Nodes to Cluster - Configuration
### ---------------------------------------------------------------------------------
### This script defines configuration variables and helper functions for adding new worker nodes to an existing OpenShift cluster.
### It is intended to be sourced by other scripts in the workflow.

### ---------------------------------------------------------------------------------
### Cluster and Node Configuration
### ---------------------------------------------------------------------------------
### Specifies the target OpenShift version for the new nodes.
OCP_VERSION="4.19.10"

### Specifies a token for non-interactive login.
### If left empty, the login function will prompt for a username and password.
OCP_USER_TOKEN=""

### Defines the new worker nodes to be added to the cluster.
### NOTE: This list should only contain the new nodes you intend to add.
###
### Defines the cluster nodes and their network interfaces.
### Format for each entry:
###   role--hostname--<Interface 1>[--<Interface 2>]...
### Format for each interface:
###   interface_name--mac_address--ip_address--prefix--destination--gateway--table_id
NODE_INFO_LIST=(
    "worker--ifr03--enp1s0--10:54:00:7d:e1:23--11.119.120.123--24--0.0.0.0/0--11.119.120.28--254"
    "worker--wrk01--enp1s0--10:54:00:7d:e1:31--11.119.120.131--24--0.0.0.0/0--11.119.120.28--254"
    "worker--wrk02--enp1s0--10:54:00:7d:e1:32--11.119.120.132--24--0.0.0.0/0--11.119.120.28--254"
)
NODE_INFO_LIST=(
    "worker--ifr03--enp1s0--10:54:00:7d:e1:23--11.119.120.123--24--0.0.0.0/0--11.119.120.28--254"
)

### Defines the cluster's name and base domain.
CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"

### ---------------------------------------------------------------------------------
### Tool and System Configuration
### ---------------------------------------------------------------------------------
### Specifies the base directory where installation tools are stored.
TOOLS_BASE_DIR="/root/ocp4/download/$OCP_VERSION/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"

### Specifies the root device for the new nodes.
ROOT_DEVICE_NAME="/dev/vda"

### Specifies DNS server addresses.
DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

### Defines parameters for polling CSRs and node status.
MAX_ATTEMPTS=30
ATTEMPT=3
CHECK_INTERVAL=30

######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### ---------------------------------------------------------------------------------
### Helper Functions
### ---------------------------------------------------------------------------------
### The following functions validate inputs and manage cluster login.

### Checks if a specified file exists.
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Required file not found: '$file'. Exiting..."
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

### Defines the API server URL.
API_SERVER="https://api.$CLUSTER_NAME.$BASE_DOMAIN:6443"

### Logs into the OpenShift cluster using a token or username/password.
login_to_cluster() {
    printf "%-8s%-80s\n" "[INFO]" "=== Logging into OpenShift Cluster ==="
    printf "%-8s%-80s\n" "[INFO]" "--- Attempting to log in to the API server at $API_SERVER..."

    if [[ -n "$OCP_USER_TOKEN" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    OCP_USER_TOKEN is set. Attempting login with token..."
        set +e
        output=$(./oc login "$API_SERVER" --token="$OCP_USER_TOKEN" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to log in with the provided token. Exiting..."
            printf "%-8s%-80s\n" "[ERROR]" "    - Message: $output"
            exit 1
        fi
    else
        ### Prompt for username and password if a token is not provided.
        printf "%-8s%-80s\n" "[INFO]" "    OCP_USER_TOKEN is not set. Prompting for username and password."
        read    -p "            Enter OpenShift username: " username
        read -s -p "            Enter OpenShift password: " password
        echo ""
        validate_non_empty "username" "$username"
        validate_non_empty "password" "$password"

        set +e
        output=$(./oc login "$API_SERVER" --username="$username" --password="$password" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to log in with the provided credentials. Exiting..."
            printf "%-8s%-80s\n" "[ERROR]" "    - Message: $output"
            exit 1
        fi
    fi
    ### Verify that the login was successful.
    if ! ./oc whoami >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[ERROR]" "    Login verification failed. Could not confirm authentication. Exiting..."
        exit 1
    fi
}