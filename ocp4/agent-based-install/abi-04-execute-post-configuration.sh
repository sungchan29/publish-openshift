#!/bin/bash

export PATH=$PATH:$(pwd)

### Define the log file name for the script.
log_file="$(basename "$0" .sh).log"

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." > $log_file
    exit 1
fi
if ! source "$config_file"; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..." > $log_file
    exit 1
fi

### Validate required variables
validate_non_empty "NODE_ROLE_SELECTORS"               "$NODE_ROLE_SELECTORS"
validate_non_empty "MAX_TRIES"                         "$MAX_TRIES"
validate_non_empty "TIMEOUT"                           "$TIMEOUT"
validate_non_empty "INSTALL_COMPLETE_LOG_FILE"         "$INSTALL_COMPLETE_LOG_FILE"
validate_non_empty "NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD"
validate_non_empty "INSTALL_COMPLETE_SEARCH_KEYWORD"   "$INSTALL_COMPLETE_SEARCH_KEYWORD"

# Validate binaries
if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Required binaries (openshift-install, oc) not found. Exiting..." > $log_file
    exit 1
fi

# PID file
pid_file="./$(basename "$0").$(realpath "$0" | md5sum | cut -d' ' -f1).pid"
# Check if the script is already running
if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file")
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! -d "/proc/$pid" ]]; then
        rm -f "$pid_file"
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script is already running with PID $pid. Exiting..." > "$log_file"
        exit 1
    fi
fi

echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script has started successfully." > "$log_file"

# Save the current PID to the PID file
echo $$ > "$pid_file"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Script PID ($$) saved to $pid_file." | tee -a $log_file
# Trap to handle script exit
trap "rm -f '$pid_file'" EXIT

install_complete_status=""
tries=1
while [[ $tries -le $MAX_TRIES ]]; do
    ./openshift-install agent wait-for install-complete  --dir $CLUSTER_NAME --log-level=debug > "$INSTALL_COMPLETE_LOG_FILE" 2>&1 &
    openshift_install_process_pid=$!
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Started 'openshift-install' process with PID: $openshift_install_process_pid." | tee -a $log_file
    
    if [[ $tries -eq 1 ]]; then
        sleep 60
    fi

    all_labels_applied=false
    start_time=$(date +%s)
    node_label_trigger_search_result=""
    while [[ -f "$INSTALL_COMPLETE_LOG_FILE" && -d "/proc/$openshift_install_process_pid" ]]; do
        sleep 5
        # Apply node labels if not already applied
        if [[ -n "$NODE_ROLE_SELECTORS" && "$all_labels_applied" = "false" ]]; then
            if [[ -z "$node_label_trigger_search_result" ]] && grep -q "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
                node_label_trigger_search_result="OK"
            fi
            if [[ -n "$node_label_trigger_search_result" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Applying node labels..." | tee -a $log_file
                all_labels_applied=true
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    node_role=$(  echo "$node_role_selector" | awk -F "--" '{print $1}')
                    node_name=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                    nodes="$(timeout 3s ./oc get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null | egrep -E "${node_name}")"
                    if [[ -n "$nodes" ]]; then
                        for node in $nodes; do
                            if timeout 3s ./oc get node "$node" --show-labels 2>/dev/null | grep -q "node-role.kubernetes.io/${node_role}="; then
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Node: $node already labeled with role: $node_role. Skipping..." | tee -a $log_file
                            else
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Labeling node: $node with role: $node_role" | tee -a $log_file
                                timeout 3s ./oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite | tee -a $log_file 2>&1
                                sleep 2
                                if ! timeout 3s ./oc get node "$node" --show-labels 2>/dev/null | grep -q "node-role.kubernetes.io/${node_role}="; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to label node: $node with role: $node_role" | tee -a $log_file
                                    all_labels_applied=false
                                    continue
                                fi
                            fi
                        done
                    else
                        all_labels_applied=false
                    fi
                done

                if [[ "$all_labels_applied" = "true" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] All labels successfully applied." | tee -a $log_file
                fi
            else
                if [[ -z "$node_label_trigger_search_result" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] No trigger string is found in the log file. Skipping node labeling." | tee -a $log_file
                fi
            fi
        fi
        
        # Check if the process is complete by searching for the completion keyword in the log file.
        if tail -n 10 "$INSTALL_COMPLETE_LOG_FILE" | grep -q "$INSTALL_COMPLETE_SEARCH_KEYWORD"; then
            install_complete_status="SUCCESS"
            break
        fi

        # Check if the process has exceeded the timeout limit.
        if [[ $(( $(date +%s) - start_time )) -ge $TIMEOUT ]]; then
            echo "" | tee -a $log_file
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Command 'install-complete' timed out after $TIMEOUT seconds." | tee -a $log_file
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Attempting to kill the process $openshift_install_process_pid due to timeout." | tee -a $log_file
            kill "$openshift_install_process_pid"
            sleep 1
            if [[ -d "/proc/$openshift_install_process_pid" ]]; then
                kill -9 "$openshift_install_process_pid"
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process $openshift_install_process_pid was not terminated by SIGTERM, sending SIGKILL." | tee -a $log_file
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process $openshift_install_process_pid has already been terminated." | tee -a $log_file
            fi
            break
        fi

        # Log progress
        if [[ -z "$NODE_ROLE_SELECTORS" || "$all_labels_applied" = "true" ]]; then
            echo -n "." | tee -a $log_file 
        fi
    done

    if [[ "$all_labels_applied" = "true" ]]; then
        echo "" | tee -a $log_file
    fi

    if [[ "$install_complete_status" = "SUCCESS" ]]; then
        break
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Process $openshift_install_process_pid is no longer running." | tee -a $log_file

        if [[ $tries -lt $MAX_TRIES ]]; then
            tries=$((tries + 1))
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Trying process ($tries/$MAX_TRIES)..." | tee -a $log_file
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Process failed after $MAX_TRIES attempts." | tee -a $log_file
        fi
    fi
done

### Excute 
if [[ "$install_complete_status" = "SUCCESS" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Cluster is installed." | tee -a $log_file

    ### Execute post configuration files
    source_dir="$(dirname "$(realpath "$0")")/abi-00-config-03-post-configuration-files"
    if [[ ! -d "$source_dir" ]]; then
        echo "[ERROR] Custom files directory '$source_dir' does not exist. Exiting..." | tee -a $log_file
    fi

    echo "[INFO] Executing post configuration files from '$source_dir'..." | tee -a $log_file
    for file_name in $(ls -1 "$source_dir" | sort -V); do
        post_configuration_file="$source_dir/$file_name"

        bash "$post_configuration_file" | tee -a $log_file

        if [[ $? -ne 0 ]]; then
            echo "[ERROR] Failed to execute '$post_configuration_file'. Check script for errors." | tee -a $log_file
        fi
        echo "[INFO] Successfully executed '$post_configuration_file'." | tee -a $log_file
        sleep 1
    done

    echo "" | tee -a $log_file
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Monitoring OpenShift components to ensure a stable state after applying custom TLS configuration..." | tee -a $log_file
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Watching MachineConfigPool (MCP) and ClusterOperators (CO) status. Ensure all components return to a stable state." | tee -a $log_file
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] For example, you can use the following command to monitor the status: watch -n 3 oc get mcp,co" | tee -a $log_file
    echo "" | tee -a $log_file
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Process completed successfully." | tee -a $log_file
fi