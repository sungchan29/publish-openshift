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

if [[ -n $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA && -n $INGRESS_CUSTOM_TLS_KEY && -n $INGRESS_CUSTOM_TLS_CERT ]]; then
    ### Create a config map that includes only the root CA certificate used to sign the wildcard certificate
    oc create configmap ${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA} \
        --from-file=ca-bundle.crt=${INGRESS_CUSTOM_ROOT_CA} \
        -n openshift-config

    ### Update the cluster-wide proxy configuration with the newly created config map
    oc patch proxy/cluster --type=merge --patch "{\"spec\":{\"trustedCA\":{\"name\":\"${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA}\"}}}"


    ### Create a secret that contains the wildcard certificate chain and key
    oc create secret tls ${SECRET_INGRESS_CUSTOM_TLS} \
        --cert=${INGRESS_CUSTOM_TLS_CERT} --key=${INGRESS_CUSTOM_TLS_KEY} \
        -n openshift-ingress

    ### Update the Ingress Controller configuration with the newly created secret
    oc patch ingresscontroller.operator default --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"${SECRET_INGRESS_CUSTOM_TLS}\"}}}"
        -n openshift-ingress-operator

    ### Verify the update was effective:
    echo Q | \
        openssl s_client -connect console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}:443 -showcerts 2>/dev/null | \
        openssl x509 -noout -subject -issuer -enddate
fi
```

```bash
#!/bin/bash

LOG_FILE="./script_execution.log"

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Starting the script execution..." >> "$LOG_FILE"

# Source the configuration file
CONFIG_FILE="./abi-01-config-preparation-01-general.sh"
if [[ -f $CONFIG_FILE ]]; then
    source "$CONFIG_FILE"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Successfully loaded configuration from $CONFIG_FILE" >> "$LOG_FILE"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Cannot access '$CONFIG_FILE'. File or directory does not exist. Exiting..." >> "$LOG_FILE"
    exit 1
fi

# Validate required variables
if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: CLUSTER_NAME variable is empty. Exiting..." >> "$LOG_FILE"
    exit 1
fi

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: BASE_DOMAIN variable is empty. Exiting..." >> "$LOG_FILE"
    exit 1
fi

# Validate required binary
if [[ -f ./oc ]]; then
    export KUBECONFIG="./${CLUSTER_NAME}/auth/kubeconfig"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Using kubeconfig: $KUBECONFIG" >> "$LOG_FILE"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Required binary (oc) not found. Exiting..." >> "$LOG_FILE"
    exit 1
fi

# Check if necessary variables are set
if [[ -n $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA && -n $INGRESS_CUSTOM_TLS_KEY && -n $INGRESS_CUSTOM_TLS_CERT ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Starting Ingress TLS and Custom CA Configuration..." >> "$LOG_FILE"

    ### Create a config map with the root CA certificate
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Creating ConfigMap: $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA" >> "$LOG_FILE"
    oc create configmap ${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA} \
        --from-file=ca-bundle.crt=${INGRESS_CUSTOM_ROOT_CA} \
        -n openshift-config >> "$LOG_FILE" 2>&1

    ### Update the cluster-wide proxy configuration
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Patching the cluster-wide proxy configuration..." >> "$LOG_FILE"
    oc patch proxy/cluster --type=merge --patch "{\"spec\":{\"trustedCA\":{\"name\":\"${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA}\"}}}" >> "$LOG_FILE" 2>&1

    ### Create a secret with the wildcard certificate and key
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Creating Secret: $SECRET_INGRESS_CUSTOM_TLS" >> "$LOG_FILE"
    oc create secret tls ${SECRET_INGRESS_CUSTOM_TLS} \
        --cert=${INGRESS_CUSTOM_TLS_CERT} --key=${INGRESS_CUSTOM_TLS_KEY} \
        -n openshift-ingress >> "$LOG_FILE" 2>&1

    ### Update the Ingress Controller configuration
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Patching the Ingress Controller with the new TLS certificate..." >> "$LOG_FILE"
    oc patch ingresscontroller.operator default --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"${SECRET_INGRESS_CUSTOM_TLS}\"}}}" \
        -n openshift-ingress-operator >> "$LOG_FILE" 2>&1

    ### Verify the update was effective
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Verifying TLS certificate update..." >> "$LOG_FILE"
    echo Q | \
        openssl s_client -connect console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}:443 -showcerts 2>/dev/null | \
        openssl x509 -noout -subject -issuer -enddate >> "$LOG_FILE" 2>&1

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Ingress TLS and Custom CA Configuration completed successfully!" >> "$LOG_FILE"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Required variables for TLS configuration are missing. Exiting..." >> "$LOG_FILE"
    exit 1
fi

echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script execution completed." >> "$LOG_FILE"

```