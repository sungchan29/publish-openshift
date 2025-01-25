```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="$(basename "$0" .sh).log"

### Log file for install-complete
INSTALL_COMPLETE_LOG_FILE=$(realpath "./wait-for_install-complete.log")
INSTALL_COMPLETE_SEARCH_KEYWORD="Cluster is installed"
NODE_LABEL_TRIGGER_SEARCH_KEYWORD="cluster bootstrap is complete"

MAX_RETRIES=2

### Timeout for OpenShift commands
#TIMEOUT=7200  # 120 minutes (in seconds)
TIMEOUT=1200  #(in seconds)


# Source the configuration file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..." > $LOG_FILE
    exit 1
fi

# Validate cluster name
if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: CLUSTER_NAME variable is empty. Exiting..." > $LOG_FILE
    exit 1
fi

# Validate binaries
if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Required binaries (openshift-install, oc) not found. Exiting..." > $LOG_FILE
    exit 1
fi

# PID file
PID_FILE="./$(basename "$0").$(realpath "$0" | md5sum | cut -d' ' -f1).pid"
# Check if the script is already running
if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE")
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! -d "/proc/$pid" ]]; then
        rm -f "$PID_FILE"
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Script is already running with PID $pid. Exiting..." >> "$LOG_FILE"
        exit 1
    fi
fi
# Save the current PID to the PID file
echo $$ > "$PID_FILE"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Script PID ($$) saved to $PID_FILE." >> "$LOG_FILE"
# Trap to handle script exit
trap "rm -f '$PID_FILE'" EXIT

###
### Script start
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Script has started successfully." > "$LOG_FILE"

INSTALL_COMPLETE_STATUS=""
RETRIES=0
while [[ $RETRIES -lt $MAX_RETRIES ]]; do
    ./openshift-install agent wait-for install-complete  --dir $CLUSTER_NAME --log-level=debug > "$INSTALL_COMPLETE_LOG_FILE" 2>&1 &
    openshift_install_process_pid=$!
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Started 'openshift-install' process with PID: $openshift_install_process_pid." >> "$LOG_FILE"
    sleep 3

    all_labels_applied=false
    start_time=$(date +%s)
    node_label_trigger_search_result=""
    while [[ -f "$INSTALL_COMPLETE_LOG_FILE" && -d "/proc/$openshift_install_process_pid" ]]; do
        # Apply node labels if not already applied
        if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
            if [[ -z $node_label_trigger_search_result ]]; then
                node_label_trigger_search_result=$(grep "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE" || true)
            fi
            if [[ -n $node_label_trigger_search_result && $all_labels_applied = "false" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Applying node labels..." >> $LOG_FILE
                all_labels_applied=true  # Assume success initially
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    if [[ ! "$node_role_selector" =~ ^[a-zA-Z0-9_\-]+--[a-zA-Z0-9_\-]+$ ]]; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] WARNING: Invalid node role selector format: $node_role_selector. Skipping."
                        continue
                    fi
                    node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
                    node_prefix=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                    nodes="$(timeout 10s oc get nodes --no-headers -o custom-columns=":metadata.name" | grep "${node_prefix}")"
                    if [[ -n $nodes ]]; then
                        for node in $nodes; do
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Checking labels for node: $node" >> "$LOG_FILE"
                            if [[ -z $(timeout 10s oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=") ]]; then
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Labeling node: $node with role: $node_role" >> $LOG_FILE
                                # Try to apply label with timeout
                                if ! timeout 10s oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite=true >> $LOG_FILE 2>&1; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to label node: $node with role: $node_role" >> $LOG_FILE
                                    all_labels_applied=false  # Mark as false if any labeling fails
                                    continue
                                fi
                                sleep 2
                                if [[ -z $(timeout 10s oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=") ]]; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Verification failed for node: $node, role: $node_role" >> $LOG_FILE
                                    all_labels_applied=false
                                    continue
                                fi
                            else
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Node: $node already labeled with role: $node_role. Skipping..." >> $LOG_FILE
                            fi
                        done
                    else
                        all_labels_applied=false
                    fi
                done

                if [[ "$all_labels_applied" == "true" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: All labels successfully applied." >> $LOG_FILE
                fi
            else
                if [[ -z $node_label_trigger_search_result ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: No trigger string found in log file. Skipping label application." >> $LOG_FILE
                fi
            fi
        fi

        ###
        if grep "$INSTALL_COMPLETE_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
            INSTALL_COMPLETE_STATUS="SUCCESS"
            echo "" >> "$LOG_FILE"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Process completed successfully." >> "$LOG_FILE"
            break
        fi

        if [[ ! -d "/proc/$openshift_install_process_pid" ]]; then
            break
        fi

        if [[ $(( $(date +%s) - start_time )) -ge $TIMEOUT ]]; then
            echo "" >> "$LOG_FILE"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Command 'install-complete' timed out after $TIMEOUT seconds." >> "$LOG_FILE"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Attempting to kill the process $openshift_install_process_pid due to timeout." >> "$LOG_FILE"
            kill "$openshift_install_process_pid"
            sleep 1
            if [[ -d "/proc/$openshift_install_process_pid" ]]; then
                kill -9 "$openshift_install_process_pid"
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Process $openshift_install_process_pid was not terminated by SIGTERM, sending SIGKILL." >> "$LOG_FILE"
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Process $openshift_install_process_pid has already been terminated." >> "$LOG_FILE"
            fi
            break
        fi
        if [[ -z $NODE_ROLE_SELECTORS || $all_labels_applied = "true" ]]; then
            echo -n "." >> "$LOG_FILE"
        fi
        sleep 5
    done

    if [[ $INSTALL_COMPLETE_STATUS = "SUCCESS" ]]; then
        break
    else
        if [[ -f "$INSTALL_COMPLETE_LOG_FILE" ]]; then
            if grep "$INSTALL_COMPLETE_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Process completed successfully." >> "$LOG_FILE"
                break
            fi
        fi
        if [[ ! -d "/proc/$openshift_install_process_pid" ]]; then
            echo "" >> "$LOG_FILE"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process $openshift_install_process_pid is no longer running." >> "$LOG_FILE"
        fi
        if [[ $RETRIES -lt $MAX_RETRIES ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Retrying process ($RETRIES/$MAX_RETRIES)..." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process failed after $MAX_RETRIES attempts." >> "$LOG_FILE"
            exit 1
        fi
        RETRIES=$((RETRIES + 1))
    fi
done

###
### Log script completion
###
echo "" >> "$LOG_FILE"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Script completed successfully." >> "$LOG_FILE"
exit 0
```



```bash

nohup sh abi-06-wait-for-install-complete.sh > /dev/null 2>&1 &

```