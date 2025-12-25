#!/bin/bash

### ---------------------------------------------------------------------------------
### Add Worker Nodes to Cluster - Configuration
### ---------------------------------------------------------------------------------
### This script defines configuration variables and helper functions required to add new worker nodes to an existing OpenShift cluster.
### It is intended to be sourced by other scripts in the workflow.

### ---------------------------------------------------------------------------------
### Cluster and Node Configuration
### ---------------------------------------------------------------------------------
### Specifies the target OpenShift version for the new nodes.
OCP_VERSION="4.20.6"

### [Option 1] Kubeconfig File (Recommended for Automation)
### Specifies the absolute path to the administrative kubeconfig file.
### - Default: Points to the local ABI installation output directory.
### - Example: "/root/agent-based/install/ocp4-mgc01/auth/kubeconfig"
KUBECONFIG="/root/agent-based/install/ocp4-mgc01/auth/kubeconfig"

### [Option 2] User Token (Alternative Access)
### Defines credentials and access paths for the OpenShift cluster.
### Authentication Priority: KUBECONFIG > OCP_USER_TOKEN > Interactive Login.
### Specifies a Service Account token or User token for non-interactive login.
### - Used if KUBECONFIG is unavailable or explicitly required.
### - If left empty, the script will prompt for Username and Password interactively.
OCP_USER_TOKEN=""

### Defines the new worker nodes to be added to the cluster.
### NOTE: This list should strictly contain ONLY the new nodes you intend to add.
###
### Format for each entry:
###   role--hostname--<Interface 1>[--<Interface 2>]...
### Format for each interface:
###   interface_name--mac_address--ip_address--prefix--destination--gateway--table_id
NODE_INFO_LIST=(
    "worker--wkr01--enp1s0--10:54:00:7d:e1:31--172.16.120.131--24--0.0.0.0/0--172.16.120.29--254"
)

### Defines the cluster's name and base domain.
CLUSTER_NAME="ocp4-mgc01"
BASE_DOMAIN="cloudpang.lan"

### ---------------------------------------------------------------------------------
### Tool and System Configuration
### ---------------------------------------------------------------------------------
### Specifies the base directory where installation tools are stored.
TOOLS_BASE_DIR="/root/ocp4/download/4.20.6/export/tool-binaries"
OPENSHIFT_CLIENT_TAR_FILE="${TOOLS_BASE_DIR}/openshift-client-linux-amd64-rhel9.tar.gz"

### Specifies the root device hint for the new nodes.
ROOT_DEVICE_NAME="/dev/vda"

### Specifies the DNS server addresses.
DNS_SERVER_01="172.16.120.29"
DNS_SERVER_02=""

### CSR and Node Status Polling Parameters
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
### The following functions validate inputs and manage cluster authentication.

### Validates that the specified file exists.
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Required file not found: '$file'. Exiting..."
        exit 1
    fi
}

### Validates that the variable has a non-empty value.
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

### Authenticates with the OpenShift cluster using Kubeconfig, Token, or Interactive Login.
login_to_cluster() {
    printf "%-8s%-80s\n" "[INFO]" "=== OpenShift Cluster Authentication ==="
    printf "%-8s%-80s\n" "[INFO]" "    > Connecting to API Server: $API_SERVER"

    if [[ -n "$KUBECONFIG" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    > Valid KUBECONFIG variable detected."
        printf "%-8s%-80s\n" "[INFO]" "      --> Using configuration file: $KUBECONFIG"
        export KUBECONFIG="$KUBECONFIG"
        printf "%-8s%-80s\n" "[INFO]" "          Current Context: $(env | grep KUBECONFIG | cut -d= -f2)"
    elif [[ -n "$OCP_USER_TOKEN" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    > OCP_USER_TOKEN detected. Authenticating via token..."
        set +e
        output=$(./oc login "$API_SERVER" --token="$OCP_USER_TOKEN" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "      Token authentication failed. Operation aborted."
            printf "%-8s%-80s\n" "[ERROR]" "      - Details: $output"
            exit 1
        fi
    else
        ### Prompt for username and password if no automated method is available.
        printf "%-8s%-80s\n" "[INFO]" "    > No automated credentials found. Starting interactive login."
        read    -p "          Enter Cluster Username: " username
        read -s -p "          Enter Cluster Password: " password
        echo ""
        validate_non_empty "username" "$username"
        validate_non_empty "password" "$password"

        set +e
        output=$(./oc login "$API_SERVER" --username="$username" --password="$password" --insecure-skip-tls-verify 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -ne 0 ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    > Authentication failed. Operation aborted."
            printf "%-8s%-80s\n" "[ERROR]" "      - Details: $output"
            exit 1
        fi
    fi

    ### Verify session validity.
    if ! ./oc whoami >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[ERROR]" "    > Session verification failed. Identity unconfirmed. Exiting..."
        exit 1
    else
        printf "%-8s%-80s\n" "[INFO]" "    > Authentication successful. Logged in as: $(./oc whoami)"
    fi
}