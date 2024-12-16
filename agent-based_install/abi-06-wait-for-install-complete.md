
```bash

vi abi-06-wait-for-install-complete.sh

```

```bash
#!/bin/bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..." > cluster-install-history.log 2>&1
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..." > cluster-install-history.log 2>&1
    exit 1
fi

if [[ -f ./openshift-install && -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"

    attempt=0
    max_attempts=3
    bootstrap_complete_result=""

    while [[ -z "$bootstrap_complete_result" && $attempt -lt $max_attempts ]]; do
        ((attempt++))

        echo "[$(date +"%Y-%m-%d %H:%M:%S")] bootstrap-complete: Attempt #$attempt"                         >> cluster-install-history.log

        ./openshift-install agent wait-for bootstrap-complete --dir ./${CLUSTER_NAME} --log-level=debug     >> cluster-install-history.log 2>&1

        bootstrap_complete_result=$(tail -10 cluster-install-history.log | grep "Bootstrap is complete")

        if [[ -n "$bootstrap_complete_result" ]]; then
            if [[ -n "$NODE_ROLE_SELECTORS" ]]; then
                for node_role_selector in $NODE_ROLE_SELECTORS; do
                    node_role=$(   echo $node_role_selector | awk -F "--" '{print $1}' )
                    node_prefix=$( echo $node_role_selector | awk -F "--" '{print $2}' )
                    if [[ -n "$node_role" && -n "$node_prefix" ]]; then
                        oc label  node <node_name> node-role.kubernetes.io/${node_role} --overwrite=true
                    fi
                done
            fi
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] No valid result found, retrying..."                        >> cluster-install-history.log
        fi
    done

    
    attempt=0
    max_attempts=3
    install_complete_result=""

    while [[ -z "$install_complete_result" && $attempt -lt $max_attempts ]]; do
        ((attempt++))

        echo ""                                                                                             >> cluster-install-history.log
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Check bootstrap-complete: Attempt #$attempt"                   >> cluster-install-history.log

        nohup ./openshift-install agent wait-for install-complete --dir ./${CLUSTER_NAME} --log-level=debug >> cluster-install-history.log 2>&1

        install_complete_result=$(tail -10 cluster-install-history.log | grep "Install complete!")

        if [[ -z "$bootstrap_complete_result" ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] No valid result found, retrying..."                        >> cluster-install-history.log
        fi

    done
fi
```



```bash

nohup sh abi-06-wait-for-install-complete.sh > /dev/null 2>&1 &

```