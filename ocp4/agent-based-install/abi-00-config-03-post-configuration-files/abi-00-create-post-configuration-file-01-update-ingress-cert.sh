#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

###
### Ingress TLS and Custom CA Configuration
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/security_and_compliance/configuring-certificates#replacing-default-ingress

if [[ -f "$INGRESS_CUSTOM_ROOT_CA" && -f "$INGRESS_CUSTOM_TLS_KEY" && -f "$INGRESS_CUSTOM_TLS_CERT" ]]; then
    ### Validate required variables
    validate_non_empty "CONFIGMAP_INGRESS_CUSTOM_ROOT_CA"  "$CONFIGMAP_INGRESS_CUSTOM_ROOT_CA"
    validate_non_empty "SECRET_INGRESS_CUSTOM_TLS"         "$SECRET_INGRESS_CUSTOM_TLS"

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Starting Ingress TLS and Custom CA Configuration..."

    ### Create a config map that includes only the root CA certificate used to sign the wildcard certificate
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Creating ConfigMap: $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA"

    oc create configmap $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA \
        --from-file=ca-bundle.crt=$INGRESS_CUSTOM_ROOT_CA \
        -n openshift-config
    
    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ConfigMap created successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to create ConfigMap."
    fi

    ### Update the cluster-wide proxy configuration with the newly created config map
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Patching the cluster-wide proxy configuration..."

    oc patch proxy/cluster \
        --type=merge \
        --patch "{\"spec\":{\"trustedCA\":{\"name\":\"$CONFIGMAP_INGRESS_CUSTOM_ROOT_CA\"}}}"

    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Proxy configuration patched successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to patch proxy configuration."
    fi

    ### Create a secret that contains the wildcard certificate chain and key
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Creating Secret: $SECRET_INGRESS_CUSTOM_TLS"

    oc create secret tls $SECRET_INGRESS_CUSTOM_TLS \
        --cert=$INGRESS_CUSTOM_TLS_CERT --key=$INGRESS_CUSTOM_TLS_KEY \
        -n openshift-ingress

    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ConfigMap created successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to create Secret."
    fi

    ### Update the Ingress Controller configuration with the newly created secret
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Patching the Ingress Controller with the new TLS certificate..."

    oc patch ingresscontroller.operator default \
        --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"$SECRET_INGRESS_CUSTOM_TLS\"}}}" \
        -n openshift-ingress-operator

    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to patch IngressController(DefaultCertificate)."
    fi
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi