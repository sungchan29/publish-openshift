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

if [[ -z "${OCP_VERSION}" ]]; then
    echo "Error: OCP_VERSION variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
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

oc create configmap ${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA} \
    --from-file=ca-bundle.crt=${INGRESS_CUSTOM_ROOT_CA} \
    -n openshift-config

oc patch proxy/cluster --type=merge \
    --patch='{"spec":{"trustedCA":{"name":"${CONFIGMAP_INGRESS_CUSTOM_ROOT_CA}"}}}'

oc create secret tls ${SECRET_INGRESS_CUSTOM_TLS} \
    --cert=${INGRESS_CUSTOM_TLS_CERT} --key=${INGRESS_CUSTOM_TLS_KEY} \
    -n openshift-ingress

oc patch ingresscontroller.operator default --type=merge \
    -p '{"spec":{"defaultCertificate": {"name": "${SECRET_INGRESS_CUSTOM_TLS}"}}}' \
    -n openshift-ingress-operator
