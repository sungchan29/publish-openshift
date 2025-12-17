#!/bin/bash

### ---------------------------------------------------------------------------------
### Execute Post-Configuration Scripts
### ---------------------------------------------------------------------------------
### This script applies user-defined post-installation configurations to a newly
### installed OpenShift cluster once the API server becomes available.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### Set the KUBECONFIG environment variable to point to the cluster's kubeconfig file.
export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
if [[ ! -f "$KUBECONFIG" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "The KUBECONFIG file at '$KUBECONFIG' was not found. Cannot connect to the cluster. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Check API Server Status
### ---------------------------------------------------------------------------------
### Checks if the OpenShift API server is fully ready through a multi-step process.
### 1. Basic network connectivity using curl.
### 2. Health status via the /healthz endpoint.
### 3. Availability of key cluster operators (kube-apiserver, openshift-apiserver, ingress).
###
### @return Returns 0 on success, 1 on failure.
###
check_api_server_status() {
    local api_server="https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
    local max_attempts=10        # Max number of retry attempts.
    local timeout=15             # Timeout for each command in seconds.
    local sleep_interval=10      # Sleep interval between retries in seconds.
    local total_timeout=1800     # Global timeout for the entire function in seconds.
    local start_time=$(date +%s) # Record the start time.
    local attempt=1

    printf "%-8s%-80s\n" "[INFO]" "=== Check API Server Status ==="
    printf "%-8s%-80s\n" "[INFO]" "--- Checking API server readiness at $api_server ..."
    ### Loop for the maximum number of attempts.
    while [ $attempt -le $max_attempts ]; do
        printf "%-8s%-80s\n" "[INFO]" "    Attempt $attempt/$max_attempts: Checking API server status..."

        ### Check for total timeout to prevent an infinite loop ###
        if [[ $(( $(date +%s) - start_time )) -ge $total_timeout ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Global timeout of $total_timeout seconds reached. API server did not become ready."
            return 1
        fi

        ### Flag to track if any check fails in the current attempt.
        local check_failed=0

        ### 1. Check basic API server connectivity (curl) ###
        if curl -s --connect-timeout $timeout --insecure "$api_server" >/dev/null; then
            printf "%-8s%-80s\n" "[INFO]" "    Connectivity check to API server successful."
        else
            printf "%-8s%-80s\n" "[WARN]" "    API server is not yet reachable."
            check_failed=1
        fi

        ### 2. Check API server health endpoint (/healthz) ###
        ###    Only proceed if the previous check was successful.
        if [[ $check_failed -eq 0 ]]; then
            local health_response
            health_response=$(timeout $timeout ./oc get --raw /healthz 2>/dev/null || echo "error")
            if echo "$health_response" | grep -qi "ok"; then
                printf "%-8s%-80s\n" "[INFO]" "    Health endpoint (/healthz) is reporting 'ok'."
            else
                printf "%-8s%-80s\n" "[WARN]" "    Health endpoint check failed. Response: '$health_response'."
                check_failed=1
            fi
        fi

        ### 3. Check core cluster operator statuses ###
        ###    Only proceed if all previous checks were successful.
        if [[ $check_failed -eq 0 ]]; then
            ### 3-1. Check 'kube-apiserver' operator
            if timeout $timeout ./oc get clusteroperators kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                printf "%-8s%-80s\n" "[INFO]" "    'kube-apiserver' operator is available."
                ### 3-2. Check 'openshift-apiserver' operator
                if timeout $timeout ./oc get clusteroperators openshift-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                    printf "%-8s%-80s\n" "[INFO]" "    'openshift-apiserver' operator is available."
                    ### 3-3. Check 'ingress' operator
                    if timeout $timeout ./oc get clusteroperators ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                        printf "%-8s%-80s\n" "[INFO]" "    'ingress' operator is available."
                        ### All checks passed. Return success (0) and exit the function.
                        printf "%-8s%-80s\n" "[INFO]" "    API server is fully ready and healthy."
                        return 0
                    else
                        printf "%-8s%-80s\n" "[WARN]" "    'ingress' operator is not yet available."
                        check_failed=1
                    fi
                else
                    printf "%-8s%-80s\n" "[WARN]" "    'openshift-apiserver' operator is not yet available."
                    check_failed=1
                fi
            else
                printf "%-8s%-80s\n" "[WARN]" "    'kube-apiserver' operator is not yet available."
                check_failed=1
            fi
        fi

        ### Retry Logic ###
        ### If any check failed in this attempt, wait before the next try.
        if [[ $check_failed -eq 1 ]]; then
            sleep $sleep_interval
            ((attempt++)) || true
        fi
    done

    ### If the loop finishes after all attempts, report final failure and return 1.
    printf "%-8s%-80s\n" "[ERROR]" "    API server did not become ready after $max_attempts attempts."
    return 1
}

### ---------------------------------------------------------------------------------
### Execute Post-Configuration Scripts
### ---------------------------------------------------------------------------------
### Validate the API server status before attempting to apply any configurations.
if ! check_api_server_status; then
    printf "%-8s%-80s\n" "[ERROR]" "    API server is not ready. Aborting post-configuration tasks. Exiting..."
    exit 1
fi

### Locate the directory containing user-defined post-configuration scripts.
source_dir="$(dirname "$(realpath "$0")")/abi-00-config-03-post-configuration"
if [[ ! -d "$source_dir" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The post-configuration scripts directory '$source_dir' not found. Exiting..."
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "=== Executing post-installation configuration scripts ==="
### Iterate through sorted files in the source directory and execute each one.
for file_path in $(find "$source_dir" -mindepth 1 -maxdepth 1 -print0 | sort -zV | tr '\0' '\n'); do
    printf "%-8s%-80s\n" "[INFO]" "--- $(basename "$file_path") ..."
    ### Execute the script, redirecting its output to the parent shell.
    bash "$file_path" 2>&1
done
echo ""