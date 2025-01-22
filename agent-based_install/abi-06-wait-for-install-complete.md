```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="$(basename "$0" .sh).log"

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..." > $LOG_FILE 2>&1
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..." > $LOG_FILE 2>&1
    exit 1
fi

if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "ERROR: Required binaries (openshift-install, oc) not found." > $LOG_FILE
    exit 1
fi

bootstrap_complete_log_file="./wait-for_bootstrap-complete.log"
search_string="cluster bootstrap is complete"
timeout=3600  # 60 minutes (in seconds)

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Run the command openshift-install wait-for bootstrap-complete" > $LOG_FILE

# Run the openshift-install command and log the output
./openshift-install agent wait-for bootstrap-complete --dir ./cloudpang --log-level=info > "$bootstrap_complete_log_file" 2>&1 &
bootstrap_complete_pid=$!
run_count=1  # Initialize run count

# Start the timer
start_time=$(date +%s)

# Monitor the log file and execute the additional code after the target string is detected
while true; do
  # Calculate elapsed time
  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))

  # Check for timeout
  if [[ $elapsed_time -ge $timeout ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Timeout of $((timeout / 60)) minutes reached. Stopping the process..." >> $LOG_FILE
    kill "$bootstrap_complete_pid"
    exit 1
  fi

  # Check for the target string in the log file
  if grep -q "$search_string" "$bootstrap_complete_log_file"; then
    if ps -p "$bootstrap_complete_pid" > /dev/null; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] Found target string: '$search_string'. Stopping the process..." >> $LOG_FILE
      kill "$bootstrap_complete_pid"
    fi

    # Execute additional logic here
    if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
      for node_role_selector in $NODE_ROLE_SELECTORS; do
        if [[ "$node_role_selector" != *"--"* ]]; then
          echo "[$(date +"%Y-%m-%d %H:%M:%S")] Invalid NODE_ROLE_SELECTORS format: $node_role_selector" >> $LOG_FILE
          continue
        fi

        node_role=$(echo $node_role_selector | awk -F "--" '{print $1}')
        node_prefix=$(echo $node_role_selector | awk -F "--" '{print $2}')

        for node in $(oc get nodes -o name | awk -F "/" '{print $2}' | grep "${node_prefix}"); do
          echo "[$(date +"%Y-%m-%d %H:%M:%S")] Labeling node: $node with role: $node_role" >> $LOG_FILE
          oc label node $node node-role.kubernetes.io/${node_role}= --overwrite=true >> $LOG_FILE 2>&1
        done
      done
    fi
    break
  else
    # Check if the process is still running
    if ! ps -p "$bootstrap_complete_pid" > /dev/null; then
      if [[ $run_count -lt 2 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process for 'openshift-install' stopped unexpectedly. Restarting (Attempt $((run_count + 1)))..." >> $LOG_FILE
        ./openshift-install agent wait-for bootstrap-complete --dir ./cloudpang --log-level=info > "$bootstrap_complete_log_file" 2>&1 &
        bootstrap_complete_pid=$!
        run_count=$((run_count + 1))  # Increment run count
      else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Maximum retries reached. Exiting..." >> $LOG_FILE
        exit 1
      fi
    fi
  fi

  # Wait for 5 seconds before the next check
  sleep 5
done


install_complete_log_file="./wait-for_install-complete.log"
search_string="Cluster is installed"
timeout=3600  # 60 minutes (in seconds)

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Run the command openshift-install wait-for install-complete" >> $LOG_FILE

# Run the openshift-install command and log the output
./openshift-install agent wait-for install-complete --dir ./cloudpang --log-level=info > "$install_complete_log_file" 2>&1 &
install_complete_pid=$!
run_count=1  # Initialize run count

# Start the timer
start_time=$(date +%s)

# Monitor the log file and execute the additional code after the target string is detected
while true; do
  # Calculate elapsed time
  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))

  # Check for timeout
  if [[ $elapsed_time -ge $timeout ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Timeout of $((timeout / 60)) minutes reached. Stopping the process..." >> $LOG_FILE
    kill "$install_complete_pid"
    exit 1
  fi

  # Check for the target string in the log file
  if grep -q "$search_string" "$install_complete_log_file"; then
    if ps -p "$install_complete_pid" > /dev/null; then
      echo "[$(date +"%Y-%m-%d %H:%M:%S")] Found target string: '$search_string'. Stopping the process..." >> $LOG_FILE
      kill "$install_complete_pid"
    fi

    # Execute additional logic here
    #
    #
    #
    

    break
  else
    # Check if the process is still running
    if ! ps -p "$install_complete_pid" > /dev/null; then
      if [[ $run_count -lt 2 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Process for 'openshift-install' stopped unexpectedly. Restarting (Attempt $((run_count + 1)))..." >> $LOG_FILE
        ./openshift-install agent wait-for install-complete --dir ./cloudpang --log-level=info > "$install_complete_log_file" 2>&1 &
        install_complete_pid=$!
        run_count=$((run_count + 1))  # Increment run count
      else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Maximum retries reached. Exiting..." >> $LOG_FILE
        exit 1
      fi
    fi
  fi

  # Wait for 5 seconds before the next check
  sleep 5
done
```



```bash

nohup sh abi-06-wait-for-install-complete.sh > /dev/null 2>&1 &

```