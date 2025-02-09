```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

### Define the log file name for the script.
LOG_FILE="$(basename "$0" .sh).log"

### Source the configuration file
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

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "Error: BASE_DOMAIN variable is empty. Exiting..."
    exit 1
fi

# Validate binaries
if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Required binaries (openshift-install, oc) not found. Exiting..." > $LOG_FILE
    exit 1
fi

### Log file for install-complete
INSTALL_COMPLETE_LOG_FILE=${INSTALL_COMPLETE_LOG_FILE:="./wait-for_install-complete.log"}
NODE_LABEL_TRIGGER_SEARCH_KEYWORD=${NODE_LABEL_TRIGGER_SEARCH_KEYWORD:="cluster bootstrap is complete"}
INSTALL_COMPLETE_SEARCH_KEYWORD=${INSTALL_COMPLETE_SEARCH_KEYWORD:="Cluster is installed"}

# Set the default value for MAX_TRIES if it is not already defined.
MAX_TRIES=${MAX_TRIES:=3}

# Timeout for OpenShift commands
TIMEOUT=${TIMEOUT:=7200}  # 120 minutes

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
TRIES=1
while [[ $TRIES -le $MAX_TRIES ]]; do
    ./openshift-install agent wait-for install-complete  --dir $CLUSTER_NAME --log-level=debug > "$INSTALL_COMPLETE_LOG_FILE" 2>&1 &
    openshift_install_process_pid=$!
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Started 'openshift-install' process with PID: $openshift_install_process_pid." >> "$LOG_FILE"
    
    if [[ $TRIES -eq 1 ]]; then
        sleep 60
    else
        sleep 3
    fi

    all_labels_applied=false
    start_time=$(date +%s)
    node_label_trigger_search_result=""
    while [[ -f "$INSTALL_COMPLETE_LOG_FILE" && -d "/proc/$openshift_install_process_pid" ]]; do
        # Apply node labels if not already applied
        if [[ -n "$NODE_ROLE_SELECTORS" && "$all_labels_applied" = "false" ]]; then
            if [[ -z "$node_label_trigger_search_result" ]] && grep -q "$NODE_LABEL_TRIGGER_SEARCH_KEYWORD" "$INSTALL_COMPLETE_LOG_FILE"; then
                node_label_trigger_search_result="OK"
            fi
            if [[ -n "$node_label_trigger_search_result" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Applying node labels..." >> $LOG_FILE
                all_labels_applied=true
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    if [[ ! "$node_role_selector" =~ ^[a-zA-Z0-9_\-]+--[a-zA-Z0-9_\-]+$ ]]; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] WARNING: Invalid node role selector format: $node_role_selector. Skipping."
                        continue
                    fi
                    node_role=$(echo "$node_role_selector" | awk -F "--" '{print $1}')
                    node_prefix=$(echo "$node_role_selector" | awk -F "--" '{print $2}')
                    nodes="$(timeout 3s oc get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "${node_prefix}")"
                    if [[ -n "$nodes" ]]; then
                        for node in $nodes; do
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Checking labels for node: $node" >> "$LOG_FILE"
                            if timeout 3s oc get node "$node" --show-labels 2>/dev/null | grep -q "node-role.kubernetes.io/${node_role}="; then
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Node: $node already labeled with role: $node_role. Skipping..." >> $LOG_FILE
                            else
                                echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Labeling node: $node with role: $node_role" >> $LOG_FILE
                                timeout 3s oc label node "$node" node-role.kubernetes.io/${node_role}= --overwrite >> $LOG_FILE 2>&1
                                sleep 2
                                if ! timeout 3s oc get node "$node" --show-labels 2>/dev/null | grep -q "node-role.kubernetes.io/${node_role}="; then
                                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to label node: $node with role: $node_role" >> $LOG_FILE
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
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: All labels successfully applied." >> $LOG_FILE
                fi
            else
                if [[ -z "$node_label_trigger_search_result" ]]; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: No trigger string is found in the log file. Skipping node labeling." >> $LOG_FILE
                fi
            fi
        fi
        
        # Check if the process is complete by searching for the completion keyword in the log file.
        if tail -n 10 "$INSTALL_COMPLETE_LOG_FILE" | grep -q "$INSTALL_COMPLETE_SEARCH_KEYWORD"; then
            INSTALL_COMPLETE_STATUS="SUCCESS"
            break
        fi

        # Check if the process has exceeded the timeout limit.
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

        # Log progress
        if [[ -z $NODE_ROLE_SELECTORS || $all_labels_applied = "true" ]]; then
            echo -n "." >> "$LOG_FILE" 
        fi
        sleep 5
    done

    if [[ "$all_labels_applied" = "true" ]]; then
        echo "" >> "$LOG_FILE"
    fi

    if [[ "$INSTALL_COMPLETE_STATUS" = "SUCCESS" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Cluster is installed." >> "$LOG_FILE"
        break
    else
        if [[ ! -d "/proc/$openshift_install_process_pid" && -f "$INSTALL_COMPLETE_LOG_FILE" ]]; then
            # Verify if the process is still running by checking if the PID exists in the /proc directory.
            if [[ ! -d "/proc/$openshift_install_process_pid" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process $openshift_install_process_pid is no longer running." >> "$LOG_FILE"
            fi
            if tail -n 10 "$INSTALL_COMPLETE_LOG_FILE" | grep -q "$INSTALL_COMPLETE_SEARCH_KEYWORD"; then
                INSTALL_COMPLETE_STATUS="SUCCESS"
                break
            fi
        fi
        if [[ $TRIES -lt $MAX_TRIES ]]; then
            TRIES=$((TRIES + 1))
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Trying process ($TRIES/$MAX_TRIES)..." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Process failed after $MAX_TRIES attempts." >> "$LOG_FILE"
        fi
    fi
done

###
### Ingress TLS and Custom CA Configuration
###
if [[ "$INSTALL_COMPLETE_STATUS" = "SUCCESS" ]]; then
    if [[ -f "$INGRESS_CUSTOM_ROOT_CA" && -f "$INGRESS_CUSTOM_TLS_KEY" && -f "$INGRESS_CUSTOM_TLS_CERT" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Starting Ingress TLS and Custom CA Configuration..." >> "$LOG_FILE"

        ### Create a config map that includes only the root CA certificate used to sign the wildcard certificate
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Creating ConfigMap: $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA" >> "$LOG_FILE"

        oc create configmap ${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA} \
            --from-file=ca-bundle.crt=${INGRESS_CUSTOM_ROOT_CA} \
            -n openshift-config >> "$LOG_FILE" 2>&1
        if [[ $? -eq 0 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: ConfigMap created successfully." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to create ConfigMap." >> "$LOG_FILE"
        fi

        ### Update the cluster-wide proxy configuration with the newly created config map
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Patching the cluster-wide proxy configuration..." >> "$LOG_FILE"

        oc patch proxy/cluster \
            --type=merge \
            --patch "{\"spec\":{\"trustedCA\":{\"name\":\"${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA}\"}}}" >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Proxy configuration patched successfully." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to patch proxy configuration." >> "$LOG_FILE"
        fi

        ### Create a secret that contains the wildcard certificate chain and key
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Creating Secret: $SECRET_INGRESS_CUSTOM_TLS" >> "$LOG_FILE"

        oc create secret tls ${SECRET_INGRESS_CUSTOM_TLS} \
            --cert=${INGRESS_CUSTOM_TLS_CERT} --key=${INGRESS_CUSTOM_TLS_KEY} \
            -n openshift-ingress >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: ConfigMap created successfully." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to create Secret." >> "$LOG_FILE"
        fi

        ### Update the Ingress Controller configuration with the newly created secret
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Patching the Ingress Controller with the new TLS certificate..." >> "$LOG_FILE"

        oc patch ingresscontroller.operator default \
            --type=merge \
            -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"${SECRET_INGRESS_CUSTOM_TLS}\"}}}" \
            -n openshift-ingress-operator >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Ingress Controller patched successfully." >> "$LOG_FILE"
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to patch Ingress Controller." >> "$LOG_FILE"
        fi
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Skipping TLS configuration due to missing required variables." >> "$LOG_FILE"
    fi
    echo "" >> "$LOG_FILE"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Monitoring OpenShift components to ensure a stable state after applying custom TLS configuration..." >> "$LOG_FILE"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Watching MachineConfigPool (MCP) and ClusterOperators (CO) status. Ensure all components return to a stable state." >> "$LOG_FILE"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: For example, you can use the following command to monitor the status: watch -n 3 timeout 3s oc get mcp,co" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] INFO: Process completed successfully." >> "$LOG_FILE"
fi
```


```bash

nohup sh abi-06-wait-for-install-complete.sh > /dev/null 2>&1 &

```