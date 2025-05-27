#!/bin/bash

### Enable strict mode
set -euo pipefail

### Define the log file name with timestamp to avoid conflicts
log_file="$(basename "$0" .sh)_$(date +%Y%m%d_%H%M%S).log"

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." | tee -a "$log_file"
    exit 1
fi
if ! source "$config_file"; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..." | tee -a "$log_file"
    exit 1
fi

### Validate required variables
if [[ ${#NODE_ROLE_SELECTORS[@]} -eq 0 ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] NODE_ROLE_SELECTORS is empty or not set." | tee -a "$log_file"
fi
validate_non_empty "MAX_TRIES"                         "$MAX_TRIES"
validate_non_empty "TIMEOUT"                           "$TIMEOUT"
validate_non_empty "INSTALL_COMPLETE_LOG_FILE"         "$INSTALL_COMPLETE_LOG_FILE"
validate_non_empty "NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD"
validate_non_empty "INSTALL_COMPLETE_SEARCH_KEYWORD"   "$INSTALL_COMPLETE_SEARCH_KEYWORD"

### Validate binaries and KUBECONFIG
if [[ ! -f ./openshift-install || ! -f ./oc ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Required binaries (openshift-install, oc) not found. Exiting..." | tee -a "$log_file"
    exit 1
fi
export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
if [[ ! -f "$KUBECONFIG" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] KUBECONFIG file '$KUBECONFIG' does not exist. Exiting..." | tee -a "$log_file"
    exit 1
fi

### Function to check API server status
check_api_server_status() {
    local api_server="https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
    local max_attempts=10     # Increased attempts for stabilization
    local attempt=1
    local timeout=15          # Increased timeout for curl and oc commands
    local sleep_interval=10   # Increased interval to reduce load
    local total_timeout=1800  # 30 minutes total timeout
    local start_time=$(date +%s)

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Checking API server status: $api_server" | tee -a "$log_file"

    while [ $attempt -le $max_attempts ]; do
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Attempt $attempt of $max_attempts..." | tee -a "$log_file"

        # Check for total timeout
        if [[ $(( $(date +%s) - start_time )) -ge $total_timeout ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Total timeout of $total_timeout seconds reached. API server check failed." | tee -a "$log_file"
            return 1
        fi

        # Step 1: Check API server connectivity
        if curl -s --connect-timeout $timeout --insecure "$api_server" >/dev/null; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] API server is reachable." | tee -a "$log_file"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] Failed to reach API server (connectivity test, timeout after ${timeout}s)." | tee -a "$log_file"
            sleep $sleep_interval
            ((attempt++))
            continue
        fi

        # Step 2: Check API server health endpoint
        local health_response
        health_response=$(timeout $timeout ./oc get --raw /healthz 2>/dev/null || echo "error")
        if echo "$health_response" | grep -qi "ok"; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] API server health endpoint (/healthz) is responding with 'ok'." | tee -a "$log_file"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] API server health check failed. Response: '$health_response'." | tee -a "$log_file"
            sleep $sleep_interval
            ((attempt++))
            continue
        fi

        # Step 3: Check kube-apiserver operator status
        if timeout $timeout ./oc get clusteroperators kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] kube-apiserver operator is Available." | tee -a "$log_file"
            # Step 4: Check openshift-apiserver operator status
            if timeout $timeout ./oc get clusteroperators openshift-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] openshift-apiserver operator is Available." | tee -a "$log_file"
                # Step 5: Check ingress operator status
                if timeout $timeout ./oc get clusteroperators ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ingress operator is Available." | tee -a "$log_file"
                    return 0
                else
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] ingress operator is not Available (timeout after ${timeout}s)." | tee -a "$log_file"
                    sleep $sleep_interval
                    ((attempt++))
                    continue
                fi
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] openshift-apiserver operator is not Available (timeout after ${timeout}s)." | tee -a "$log_file"
                sleep $sleep_interval
                ((attempt++))
                continue
            fi
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] kube-apiserver operator is not Available (timeout after ${timeout}s)." | tee -a "$log_file"
            sleep $sleep_interval
            ((attempt++))
            continue
        fi
    done

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Max attempts ($max_attempts) reached. API server unhealthy." | tee -a "$log_file"
    return 1
}

### PID file
pid_file="./$(basename "$0").pid"
### Check if the script is already running
if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file")
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! -d "/proc/$pid" ]]; then
        rm -f "$pid_file"
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script is already running with PID $pid. Exiting..." | tee -a "$log_file"
        exit 1
    fi
fi

echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script has started successfully." | tee -a "$log_file"

### Save the current PID to the PID file
echo $$ > "$pid_file"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script PID ($$) saved to $pid_file." | tee -a "$log_file"
### Trap to handle script exit
trap "rm -f '$pid_file'" EXIT

install_complete_status=""
tries=1
while [[ $tries -le $MAX_TRIES ]]; do
    ./openshift-install agent wait-for install-complete --dir "$CLUSTER_NAME" --log-level=debug > "$INSTALL_COMPLETE_LOG_FILE" 2>&1 &
    openshift_install_process_pid=$!
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Started 'openshift-install' process with PID: $openshift_install_process_pid." | tee -a "$log_file"
    
    if [[ $tries -eq 1 ]]; then
        sleep 60
    fi

    all_labels_applied=false
    start_time=$(date +%s)
    node_label_trigger_search_result=""
    while [[ -f "$INSTALL_COMPLETE_LOG_FILE" && -d "/proc/$openshift_install_process_pid" ]]; do
        sleep 5
        ### Apply node labels if not already applied
        if [[ ${#NODE_ROLE_SELECTORS[@]} -gt 0 && "$all_labels_applied" = "false" ]]; then
            if [[ -z "$node_label_trigger_search_result" ]] && grep -q "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
                node_label_trigger_search_result="OK"
            fi
            if [[ -n "$node_label_trigger_search_result" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Applying node labels..." | tee -a "$log_file"
                all_labels_applied=true
                for node_role_selector in "${NODE_ROLE_SELECTORS[@]}"; do
                    node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
                    node_name=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                    ### Check API server status before labeling
                    if ! check_api_server_status; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] API server not ready, skipping node labeling retry." | tee -a "$log_file"
                        all_labels_applied=false
                        continue
                    fi
                    ### Disable set -e for oc commands
                    set +e
                    nodes=$(timeout 5s ./oc get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null | egrep -E "${node_name}" | grep "${CLUSTER_NAME}\.${BASE_DOMAIN}" || true)
                    exit_code=$?
                    set -e
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [DEBUG] oc get nodes output (exit code $exit_code): $nodes" | tee -a "$log_file"
                    if [[ -n "$nodes" && "$nodes" != "<none>" ]]; then
                        for node in $nodes; do
                            ### Check existing labels
                            set +e
                            label_check=$(timeout 5s ./oc get node "$node" --show-labels 2>/dev/null || true)
                            label_check_exit_code=$?
                            set -e
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [DEBUG] oc get node $node --show-labels output (exit code $label_check_exit_code): $label_check" | tee -a "$log_file"
                            if echo "$label_check" | grep -q "node-role.kubernetes.io/${node_role}=" 2>/dev/null; then
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Node: $node already labeled with role: $node_role. Skipping..." | tee -a "$log_file"
                            else
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Labeling node: $node with role: $node_role" | tee -a "$log_file"
                                set +e
                                timeout 5s ./oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite 2>/dev/null || true
                                label_exit_code=$?
                                set -e
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [DEBUG] oc label node $node exit code: $label_exit_code" | tee -a "$log_file"
                                sleep 2
                                ### Verify label
                                set +e
                                verify_label=$(timeout 5s ./oc get node "$node" --show-labels 2>/dev/null || true)
                                verify_exit_code=$?
                                set -e
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [DEBUG] oc get node $node --show-labels verify output (exit code $verify_exit_code): $verify_label" | tee -a "$log_file"
                                if ! echo "$verify_label" | grep -q "node-role.kubernetes.io/${node_role}=" 2>/dev/null; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] Failed to label node: $node with role: $node_role" | tee -a "$log_file"
                                    all_labels_applied=false
                                    continue
                                fi
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Successfully labeled node: $node with role: $node_role" | tee -a "$log_file"
                            fi
                        done
                    else
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARN] No nodes found matching patterns '$node_name' or '$node_name.$CLUSTER_NAME.$BASE_DOMAIN'. Retrying..." | tee -a "$log_file"
                        all_labels_applied=false
                    fi
                done

                if [[ "$all_labels_applied" = "true" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] All labels successfully applied." | tee -a "$log_file"
                fi
            else
                if [[ -z "$node_label_trigger_search_result" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Waiting for trigger string '$NODE_LABEL_TRIGGER_SEARCH_KEYWORD' in log file..." | tee -a "$log_file"
                fi
            fi
        fi
        
        ### Check if the process is complete
        if tail -n 10 "$INSTALL_COMPLETE_LOG_FILE" | grep -q "$INSTALL_COMPLETE_SEARCH_KEYWORD"; then
            install_complete_status="SUCCESS"
            break
        fi

        ### Check for timeout
        if [[ $(( $(date +%s) - start_time )) -ge $TIMEOUT ]]; then
            echo "" | tee -a "$log_file"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Command 'install-complete' timed out after $TIMEOUT seconds." | tee -a "$log_file"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Attempting to kill the process $openshift_install_process_pid due to timeout." | tee -a "$log_file"
            kill "$openshift_install_process_pid" 2>/dev/null || true
            sleep 1
            if [[ -d "/proc/$openshift_install_process_pid" ]]; then
                kill -9 "$openshift_install_process_pid" 2>/dev/null || true
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process $openshift_install_process_pid was not terminated by SIGTERM, sent SIGKILL." | tee -a "$log_file"
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process $openshift_install_process_pid has already been terminated." | tee -a "$log_file"
            fi
            break
        fi

        ### Log progress
        if [[ ${#NODE_ROLE_SELECTORS[@]} -eq 0 || "$all_labels_applied" = "true" ]]; then
            echo -n "."
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Waiting for trigger string '$INSTALL_COMPLETE_SEARCH_KEYWORD' in log file..." >> "$log_file"
        fi
    done

    if [[ "$all_labels_applied" = "true" ]]; then
        echo "" | tee -a "$log_file"
    fi

    if [[ "$install_complete_status" = "SUCCESS" ]]; then
        break
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Process $openshift_install_process_pid is no longer running." | tee -a "$log_file"

        if [[ $tries -lt $MAX_TRIES ]]; then
            tries=$((tries + 1))
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Trying process ($tries/$MAX_TRIES)..." | tee -a "$log_file"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Process failed after $MAX_TRIES attempts." | tee -a "$log_file"
            exit 1
        fi
    fi
done

### Execute post-configuration
if [[ "$install_complete_status" = "SUCCESS" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Cluster is installed." | tee -a "$log_file"

    ### Execute post configuration files
    source_dir="$(dirname "$(realpath "$0")")/abi-00-config-03-post-configuration-files"
    if [[ ! -d "$source_dir" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Custom files directory '$source_dir' does not exist. Exiting..." | tee -a "$log_file"
        exit 1
    fi

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Executing post configuration files from '$source_dir'..." | tee -a "$log_file"
    for file_name in $(ls -1 "$source_dir" | sort -V); do
        post_configuration_file="$source_dir/$file_name"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Executing $post_configuration_file..." | tee -a "$log_file"
        if ! check_api_server_status; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] API server not ready, skipping '$post_configuration_file'." | tee -a "$log_file"
            continue
        fi
        if ! bash "$post_configuration_file" 2>&1 | tee -a "$log_file"; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to execute '$post_configuration_file'. Check logs for details." | tee -a "$log_file"
            continue
        fi
    done

    echo "" | tee -a "$log_file"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Monitoring OpenShift components to ensure a stable state after applying custom TLS configuration..." | tee -a "$log_file"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Watching MachineConfigPool (MCP) and ClusterOperators (CO) status. Ensure all components return to a stable state." | tee -a "$log_file"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] For example, you can use the following command to monitor the status: watch -n 3 oc get mcp,co" | tee -a "$log_file"
    echo "" | tee -a "$log_file"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process completed successfully." | tee -a "$log_file"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cluster installation failed after $MAX_TRIES attempts. Exiting..." | tee -a "$log_file"
    exit 1
fi
