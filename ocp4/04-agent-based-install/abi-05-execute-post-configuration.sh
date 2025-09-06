#!/bin/bash

### ---------------------------------------------------------------------------------
### Execute Post-Configuration Scripts
### ---------------------------------------------------------------------------------
### This script automates the application of user-defined configurations to a newly
### installed OpenShift cluster after the API server becomes available.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Validate Prerequisites
### ---------------------------------------------------------------------------------
### Define the log file name to capture the entire script output.
log_file="$(basename "$0" .sh)_$(date +%Y%m%d_%H%M%S).log"

### Source the main configuration file to load all necessary variables.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Please check the file path." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Set the KUBECONFIG environment variable to point to the cluster's kubeconfig file.
export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
if [[ ! -f "$KUBECONFIG" ]]; then
    echo "ERROR: The KUBECONFIG file '$KUBECONFIG' does not exist. Cannot connect to the cluster." >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### Check API Server Status
### ---------------------------------------------------------------------------------
### Function to repeatedly check the API server's health and readiness.
check_api_server_status() {
    local api_server="https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
    local max_attempts=10
    local timeout=15
    local sleep_interval=10
    local total_timeout=1800
    local start_time=$(date +%s)
    local attempt=1

    echo "INFO: Checking API server status for $api_server. This may take some time..."

    while [ $attempt -le $max_attempts ]; do
        echo "INFO: Attempt $attempt of $max_attempts to reach API server..."

        # Check for total timeout to prevent infinite loops.
        if [[ $(( $(date +%s) - start_time )) -ge $total_timeout ]]; then
            echo "ERROR: Total timeout of $total_timeout seconds reached. The API server did not become ready." >&2
            return 1
        fi

        # Step 1: Check for basic API server connectivity.
        if curl -s --connect-timeout $timeout --insecure "$api_server" >/dev/null; then
            echo "INFO: API server is reachable."
        else
            echo "WARN: Failed to reach API server (connectivity test failed). Retrying in $sleep_interval seconds..."
            sleep $sleep_interval
            ((attempt++))
            continue
        fi

        # Step 2: Check the API server health endpoint.
        local health_response
        health_response=$(timeout $timeout ./oc get --raw /healthz 2>/dev/null || echo "error")
        if echo "$health_response" | grep -qi "ok"; then
            echo "INFO: API server health endpoint (/healthz) is responding with 'ok'."
        else
            echo "WARN: API server health check failed. Response: '$health_response'. Retrying in $sleep_interval seconds..."
            sleep $sleep_interval
            ((attempt++))
            continue
        fi

        # Step 3: Check core cluster operator statuses.
        if timeout $timeout ./oc get clusteroperators kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
            echo "INFO: kube-apiserver operator is Available."
            if timeout $timeout ./oc get clusteroperators openshift-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                echo "INFO: openshift-apiserver operator is Available."
                if timeout $timeout ./oc get clusteroperators ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                    echo "INFO: ingress operator is Available."
                    echo "INFO: API server is fully ready and healthy."
                    return 0
                else
                    echo "WARN: ingress operator is not Available. Retrying in $sleep_interval seconds..."
                    sleep $sleep_interval
                    ((attempt++))
                    continue
                fi
            else
                echo "WARN: openshift-apiserver operator is not Available. Retrying in $sleep_interval seconds..."
                sleep $sleep_interval
                ((attempt++))
                continue
            fi
        else
            echo "WARN: kube-apiserver operator is not Available. Retrying in $sleep_interval seconds..."
            sleep $sleep_interval
            ((attempt++))
            continue
        fi
    done

    echo "ERROR: Maximum attempts ($max_attempts) reached. API server did not become ready." >&2
    return 1
}

### ---------------------------------------------------------------------------------
### Execute Post-Configuration Scripts
### ---------------------------------------------------------------------------------
### Validate the API server status before attempting to apply configurations.
if ! check_api_server_status; then
    echo "ERROR: API server is not ready. Exiting to prevent configuration errors." >&2
    exit 1
fi

### Locate the directory containing user-defined post-configuration scripts.
source_dir="$(dirname "$(realpath "$0")")/abi-00-config-03-post-configuration"
if [[ ! -d "$source_dir" ]]; then
    echo "ERROR: The custom post-configuration directory '$source_dir' does not exist." >&2
    echo "INFO: No post-configuration scripts will be executed."
    exit 1
fi

echo "INFO: Executing post-installation configuration scripts from '$source_dir'..."

### Iterate through sorted files and execute each one.
for file_name in $(ls -1 "$source_dir" | sort -V); do
    post_configuration_file="$source_dir/$file_name"

    echo "INFO: -> Executing script: $post_configuration_file"
    
    ### Execute the script and capture its output.
    bash "$post_configuration_file" 2>&1
    
    echo "INFO: -> Script '$file_name' execution complete."
done
echo "INFO: All post-configuration scripts have been executed successfully."