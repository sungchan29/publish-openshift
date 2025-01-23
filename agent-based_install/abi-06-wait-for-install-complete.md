```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="$(basename "$0" .sh).log"

### Log file for bootstrap-complete
bootstrap_complete_log_file="./wait-for_bootstrap-complete.log"
bootstrap_search_string="cluster bootstrap is complete"

### Log file for install-complete
install_complete_log_file="./wait-for_install-complete.log"
install_search_string="Cluster is installed"

### Timeout for OpenShift commands
timeout=3600  # 60 minutes (in seconds)


# Source the configuration file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..." > $LOG_FILE
    exit 1
fi

# Validate cluster name
if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "ERROR: CLUSTER_NAME variable is empty. Exiting..." > $LOG_FILE
    exit 1
fi

# Validate binaries
if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "ERROR: Required binaries (openshift-install, oc) not found. Exiting..." > $LOG_FILE
    exit 1
fi


PID_FILE="/tmp/$(basename "$0").$(realpath "$0" | md5sum | cut -d' ' -f1).pid"
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
trap "rm -f '$PID_FILE' || echo 'Warning: Failed to delete PID file' >> $LOG_FILE" EXIT

###
### Log script start
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script has started successfully." > "$LOG_FILE"

###
### Bootstrap-complete process
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Executing 'openshift-install wait-for bootstrap-complete'..." >> $LOG_FILE

# Run the bootstrap-complete command
./openshift-install agent wait-for bootstrap-complete --dir ./cloudpang --log-level=debug > "$bootstrap_complete_log_file" 2>&1 &
bootstrap_complete_pid=$!
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Bootstrap-complete process PID: $bootstrap_complete_pid" >> $LOG_FILE
run_count=1

# Start the timer
start_time=$(date +%s)

# Monitor bootstrap-complete process
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    # Check for timeout
    if [[ $elapsed_time -ge $timeout ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Timeout of $((timeout / 60)) minutes reached. Terminating process..." >> $LOG_FILE
        if ps -p "$bootstrap_complete_pid" > /dev/null; then
            kill "$bootstrap_complete_pid"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $bootstrap_complete_pid terminated due to timeout." >> $LOG_FILE
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $bootstrap_complete_pid is not running. Skipping termination." >> $LOG_FILE
        fi
        exit 1
    fi

    # Check for the completion message
    if grep -q "$bootstrap_search_string" "$bootstrap_complete_log_file"; then
        if ps -p "$bootstrap_complete_pid" > /dev/null; then
            kill "$bootstrap_complete_pid"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $bootstrap_complete_pid terminated due to timeout." >> $LOG_FILE
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $bootstrap_complete_pid is not running. Skipping termination." >> $LOG_FILE
        fi
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Bootstrap process completed successfully." >> $LOG_FILE
        break
    fi

    # Restart process if it fails unexpectedly
    if ! ps -p "$bootstrap_complete_pid" > /dev/null; then
        if [[ $run_count -lt 2 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Bootstrap process stopped unexpectedly. Restarting (Attempt $((run_count + 1)))..." >> $LOG_FILE
            ./openshift-install agent wait-for bootstrap-complete --dir ./cloudpang --log-level=debug > "$bootstrap_complete_log_file" 2>&1 &
            bootstrap_complete_pid=$!
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Bootstrap-complete process PID: $bootstrap_complete_pid" >> $LOG_FILE
            run_count=$((run_count + 1))
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Maximum retries reached. Exiting..." >> $LOG_FILE
            exit 1
        fi
    fi

    sleep 5
done

###
### Install-complete process
###
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Executing 'openshift-install wait-for install-complete'..." >> $LOG_FILE

# Run the install-complete command
./openshift-install agent wait-for install-complete --dir ./cloudpang --log-level=debug > "$install_complete_log_file" 2>&1 &
install_complete_pid=$!
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Install-complete process PID: $install_complete_pid" >> $LOG_FILE
run_count=1
label_applied=false

# Start the timer
start_time=$(date +%s)

# Monitor install-complete process
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    # Check for timeout
    if [[ $elapsed_time -ge $timeout ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Timeout of $((timeout / 60)) minutes reached. Terminating process..." >> $LOG_FILE
        if ps -p "$install_complete_pid" > /dev/null; then
            kill "$install_complete_pid"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $install_complete_pid terminated due to timeout." >> $LOG_FILE
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $install_complete_pid is not running. Skipping termination." >> $LOG_FILE
        fi
        exit 1
    fi

    # Apply node labels if not already applied
    if [[ "$label_applied" == "false" && -n "$NODE_ROLE_SELECTORS" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Applying node labels..." >> $LOG_FILE

        label_applied=true
        for node_role_selector in $NODE_ROLE_SELECTORS; do
            node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
            node_prefix=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
            for node in $(oc get nodes --no-headers -o custom-columns=":metadata.name" | grep "${node_prefix}"); do
                if ! oc get node "$node" --show-labels | grep -q "node-role.kubernetes.io/${node_role}="; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Labeling node $node with role $node_role..." >> $LOG_FILE
                    oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite=true >> $LOG_FILE 2>&1
                    if oc get node "$node" --show-labels | grep -q "node-role.kubernetes.io/${node_role}="; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Successfully labeled node $node." >> $LOG_FILE
                    else
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Failed to label node $node." >> $LOG_FILE
                        label_applied=false
                    fi
                fi
            done
        done
    fi

    # Check for the completion message
    if grep -q "$install_search_string" "$install_complete_log_file"; then
        if ps -p "$install_complete_pid" > /dev/null; then
            kill "$install_complete_pid"
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $install_complete_pid terminated due to timeout." >> $LOG_FILE
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process $install_complete_pid is not running. Skipping termination." >> $LOG_FILE
        fi
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Installation process completed successfully." >> $LOG_FILE
        break
    fi

    # Restart process if it fails unexpectedly
    if ! ps -p "$install_complete_pid" > /dev/null; then
        if [[ $run_count -lt 2 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Install process stopped unexpectedly. Restarting (Attempt $((run_count + 1)))..." >> $LOG_FILE
            ./openshift-install agent wait-for install-complete --dir ./cloudpang --log-level=debug > "$install_complete_log_file" 2>&1 &
            install_complete_pid=$!
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Install-complete process PID: $install_complete_pid" >> $LOG_FILE
            run_count=$((run_count + 1))
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Maximum retries reached. Exiting..." >> $LOG_FILE
            exit 1
        fi
    fi

    sleep 5
done


```



```bash

nohup sh abi-06-wait-for-install-complete.sh &

```