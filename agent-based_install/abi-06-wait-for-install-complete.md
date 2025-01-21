```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

LOG_FILE="cluster-install-history.log"

# Load configuration
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist." | tee -a $LOG_FILE
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "ERROR: CLUSTER_NAME variable is empty. Exiting..." | tee -a $LOG_FILE
    exit 1
fi

# Check OpenShift binaries
if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"

    attempt=0
    max_attempts=5
    bootstrap_complete_result=""

    while [[ -z "$bootstrap_complete_result" && $attempt -lt $max_attempts ]]; do
        ((attempt++))
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] bootstrap-complete: Attempt #$attempt" | tee -a $LOG_FILE

        if ! ./openshift-install agent wait-for bootstrap-complete --dir ./${CLUSTER_NAME} --log-level=debug >> $LOG_FILE 2>&1; then
            echo "ERROR: Bootstrap command failed. Check logs for details." | tee -a $LOG_FILE
            exit 1
        fi

        bootstrap_complete_result=$(tail -10 $LOG_FILE | grep "Bootstrap is complete")

        if [[ -n "$bootstrap_complete_result" ]]; then
            if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    if [[ "$node_role_selector" != *"--"* ]]; then
                        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Invalid NODE_ROLE_SELECTORS format: $node_role_selector" | tee -a $LOG_FILE
                        continue
                    fi

                    node_role=$(echo $node_role_selector | awk -F "--" '{print $1}')
                    node_prefix=$(echo $node_role_selector | awk -F "--" '{print $2}')

                    for node in $(oc get nodes -o name | awk -F "/" '{print $2}' | grep "${node_prefix}"); do
                        if oc label node $node node-role.kubernetes.io/${node_role} --overwrite=true; then
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Successfully labeled node $node with role $node_role" | tee -a $LOG_FILE
                        else
                            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Failed to label node $node with role $node_role" | tee -a $LOG_FILE
                        fi
                    done
                done
            fi
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Bootstrap not yet complete, retrying in 3 seconds..." | tee -a $LOG_FILE
            sleep 3
        fi
    done

    attempt=0
    install_complete_result=""

    while [[ -z "$install_complete_result" && $attempt -lt $max_attempts ]]; do
        ((attempt++))
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Check install-complete: Attempt #$attempt" | tee -a $LOG_FILE

        if ! ./openshift-install agent wait-for install-complete --dir ./${CLUSTER_NAME} --log-level=debug >> $LOG_FILE 2>&1; then
            echo "ERROR: Install command failed. Check logs for details." | tee -a $LOG_FILE
            exit 1
        fi

        install_complete_result=$(tail -10 $LOG_FILE | grep "Install complete!")

        if [[ -z "$install_complete_result" ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Install not yet complete, retrying in 3 seconds..." | tee -a $LOG_FILE
            sleep 3
        fi
    done
else
    echo "ERROR: Required binaries (openshift-install, oc) not found." | tee -a $LOG_FILE
    exit 1
fi
```



```bash

nohup sh abi-06-wait-for-install-complete.sh > /dev/null 2>&1 &

```