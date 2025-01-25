```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="$(basename "$0" .sh).log"

### Log file for install-complete
INSTALL_COMPLETE_LOG_FILE="./wait-for_install-complete.log"
INSTALL_COMPLETE_SEARCH_KEYWORD="Cluster is installed"
NODE_LABEL_TRIGGER_SEARCH_KEYWORD="cluster bootstrap is complete"

MAX_RETRIES=2

### Timeout for OpenShift commands
TIMEOUT=3600  # 60 minutes (in seconds)


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
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script is already running with PID $pid. Exiting..." >> "$LOG_FILE"
        exit 1
    fi
fi
# Save the current PID to the PID file
echo $$ > "$PID_FILE"
# Trap to handle script exit
trap "rm -f '$PID_FILE'" EXIT


###
### Script start
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script has started successfully." > "$LOG_FILE"

INSTALL_COMPLETE_STATUS=""
RETRIES=0
while [[ $RETRIES -lt $MAX_RETRIES ]]; do
    ./openshift-install agent wait-for install-complete  --dir $CLUSTER_NAME --log-level=debug > "$INSTALL_COMPLETE_LOG_FILE" 2>&1 &
    process_pid=$!
    sleep 3

    if [[ -f $INSTALL_COMPLETE_LOG_FILE ]]; then
        all_labels_applied=false
        start_time=$(date +%s)
	node_label_trigger_search_result=""
        while true; do
            # Apply node labels if not already applied
            if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
                if [[ -z $node_label_trigger_search_result ]]; then
                    node_label_trigger_search_result=$(grep "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE")
                fi

                if [[ -n $node_label_trigger_search_result && $all_labels_applied = "false" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Applying node labels..." >> $LOG_FILE
                    all_labels_applied=true  # Assume success initially

                    for node_role_selector in $NODE_ROLE_SELECTORS; do
                        node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
                        node_prefix=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                        nodes=$(timeout 3s oc get nodes --no-headers -o custom-columns=":metadata.name" | grep "${node_prefix}")
                        if [[ -n $nodes ]]; then
                            for node in $nodes; do
                                current_label=$(timeout 3s oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=")

                                if [[ -z "$current_label" ]]; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Labeling node: $node with role: $node_role" >> $LOG_FILE

                                    # Try to apply label with timeout
                                    if ! timeout 3s oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite=true >> $LOG_FILE 2>&1; then
                                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to label node: $node with role: $node_role" >> $LOG_FILE
                                        all_labels_applied=false  # Mark as false if any labeling fails
                                        break
                                    fi

                                    sleep 2
                                    current_label=$(timeout 3s oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=")
                                    if [[ -z "$current_label" ]]; then
                                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Verification failed for node: $node, role: $node_role" >> $LOG_FILE
                                        all_labels_applied=false
                                        break
                                    fi
                                else
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Node: $node already labeled with role: $node_role. Skipping..." >> $LOG_FILE
                                fi
                            done
                        else
                            all_labels_applied=false
                        fi
                    done

                    if [[ "$all_labels_applied" == "true" ]]; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] All labels successfully applied." >> $LOG_FILE
                    fi
                else
                    if [[ -z $node_label_trigger_search_result ]]; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] No trigger string found in log file. Skipping label application." >> $LOG_FILE
                    fi
                fi
            fi

            if grep "$INSTALL_COMPLETE_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
                INSTALL_COMPLETE_STATUS="SUCCESS"
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process completed successfully." >> "$LOG_FILE"
                break
            else
                if [[ ! -d "/proc/$process_pid" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $process_pid is no longer running." >> "$LOG_FILE"
                    break
                fi
            fi

            if [[ $(( $(date +%s) - start_time )) -ge $TIMEOUT ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Command 'install-complete' timed out after $TIMEOUT seconds." >> "$LOG_FILE"
                if [[ -d "/proc/$process_pid" ]]; then
                    kill -9 "$process_pid"
                    break
                fi
            fi
            sleep 3
        done
    fi

    RETRIES=$((RETRIES + 1))
    if [[ "SUCCESS" = "$INSTALL_COMPLETE_STATUS" ]]; then
        break
    else
        if [[ $RETRIES -lt $MAX_RETRIES ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Retrying process ($RETRIES/$MAX_RETRIES)..." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process failed after $MAX_RETRIES attempts." >> "$LOG_FILE"
            exit 1
       fi
    fi
done

###
### Log script completion
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script completed successfully." >> "$LOG_FILE"
```



```bash

nohup sh abi-06-wait-for-install-complete.sh &

```