```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="$(basename "$0" .sh).log"

### Log file for bootstrap-complete
BOOTSTRAP_COMPLETE_LOG_FILE="./wait-for_bootstrap-complete.log"
BOOTSTRAP_SEARCH_STRING="cluster bootstrap is complete"

### Log file for install-complete
INSTALL_COMPLETE_LOG_FILE="./wait-for_install-complete.log"
INSTALL_SEARCH_STRING="Cluster is installed"


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
### Log script start
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script has started successfully." > "$LOG_FILE"


### Wait for completion with timeout and retries
wait_for_completion() {
    local command=$1
    local search_string=$2
    local log_file=$3
    local process_pid
    local retries=0

    while [[ $retries -lt $MAX_RETRIES ]]; do
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Starting process: $command..." >> "$LOG_FILE"
        ./openshift-install agent wait-for $command --dir $CLUSTER_NAME --log-level=debug > "$log_file" 2>&1 &
        process_pid=$!

        local all_labels_applied=false
        local start_time=$(date +%s)
        while true; do
            ### install-complete
            ### Apply node labels if not already applied
            if [[ "install-complete" == "$command" && "$all_labels_applied" == "false" && -n "$NODE_ROLE_SELECTORS" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Applying node labels..." >> $LOG_FILE
                all_labels_applied=true
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
                    node_prefix=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                    for node in $(oc get nodes --no-headers -o custom-columns=":metadata.name" | grep "${node_prefix}"); do
                        current_label=$(oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=" || true)
                        if [[ -z "$current_label" ]]; then
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Labeling node: $node with role: $node_role" >> $LOG_FILE
                            oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite=true >> $LOG_FILE 2>&1
                            sleep 2
                            current_label=$(oc get node "$node" --show-labels | grep "node-role.kubernetes.io/${node_role}=" || true)
                            if [[ -z "$current_label" ]]; then
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Failed to label node: $node with role: $node_role" >> $LOG_FILE
                                all_labels_applied=false  # Mark as false if labeling fails
                            fi
                        else
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Node: $node already labeled with role: $node_role. Skipping..." >> $LOG_FILE
                        fi
                    done
                done
            fi

            if grep -q "$search_string" "$log_file"; then
                if [[ -d "/proc/$process_pid" ]]; then
                    if kill -9 "$process_pid" 2>/dev/null; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $process_pid terminated." >> "$LOG_FILE"
                    else
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] WARNING: Failed to terminate process $process_pid" >> "$LOG_FILE"
                    fi
                fi
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process($command) completed successfully." >> "$LOG_FILE"
                return 0
            else
                if [[ ! -d "/proc/$process_pid" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $process_pid is no longer running." >> "$LOG_FILE"
                    break
                fi
            fi

            if [[ $(( $(date +%s) - start_time )) -ge $TIMEOUT ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Command '$command' timed out after $TIMEOUT seconds." >> "$LOG_FILE"
                if [[ -d "/proc/$process_pid" ]]; then
                    if kill -9 "$process_pid" 2>/dev/null; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $process_pid terminated." >> "$LOG_FILE"
                    else
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] WARNING: Failed to terminate process $process_pid" >> "$LOG_FILE"
                    fi
                fi
                exit 1
            fi

            sleep 5
        done

        retries=$((retries + 1))
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Retrying process ($retries/$MAX_RETRIES)..." >> "$LOG_FILE"
    done

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process($command) failed after $MAX_RETRIES attempts." >> "$LOG_FILE"
    exit 1
}

###
### bootstrap-complete process
###
wait_for_completion "bootstrap-complete" "$BOOTSTRAP_SEARCH_STRING" "$BOOTSTRAP_COMPLETE_LOG_FILE"

###
### install-complete process
###
wait_for_completion "install-complete" "$INSTALL_SEARCH_STRING" "$INSTALL_COMPLETE_LOG_FILE"


###
### Log script completion
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script completed successfully." >> "$LOG_FILE"
```



```bash

nohup sh abi-06-wait-for-install-complete.sh &

```