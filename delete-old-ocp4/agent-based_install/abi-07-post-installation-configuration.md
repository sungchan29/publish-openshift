```bash

vi abi-07-post-installation-configuration.sh

```

```bash
#!/bin/bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..."
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "Error: BASE_DOMAIN variable is empty. Exiting..."
    exit 1
fi

# Validate binary
if [[ -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Required binary (oc) not found. Exiting..." > $LOG_FILE
    exit 1
fi


#####################
#####################
#####################

```