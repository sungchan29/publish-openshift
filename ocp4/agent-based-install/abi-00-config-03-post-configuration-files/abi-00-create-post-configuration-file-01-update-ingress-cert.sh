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

    ### Create a config map with the root CA certificate
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Creating ConfigMap: $CONFIGMAP_INGRESS_CUSTOM_ROOT_CA"
    ./oc create configmap "$CONFIGMAP_INGRESS_CUSTOM_ROOT_CA" \
        --from-file=ca-bundle.crt="$INGRESS_CUSTOM_ROOT_CA" \
        -n openshift-config --dry-run=client -o yaml | ./oc apply -f -

    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ConfigMap created or updated successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to create or update ConfigMap."
        exit 1
    fi

    ### Update the cluster-wide proxy configuration
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Patching the cluster-wide proxy configuration..."
    ./oc patch proxy/cluster \
        --type=merge \
        --patch "{\"spec\":{\"trustedCA\":{\"name\":\"$CONFIGMAP_INGRESS_CUSTOM_ROOT_CA\"}}}" \
        || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to patch proxy configuration."; exit 1; }

    ### Create a secret with the wildcard certificate and key
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Creating Secret: $SECRET_INGRESS_CUSTOM_TLS"
    ./oc create secret tls "$SECRET_INGRESS_CUSTOM_TLS" \
        --cert="$INGRESS_CUSTOM_TLS_CERT" --key="$INGRESS_CUSTOM_TLS_KEY" \
        -n openshift-ingress --dry-run=client -o yaml | ./oc apply -f -

    if [[ $? -eq 0 ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Secret created or updated successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to create or update Secret."
        exit 1
    fi

    ### Update the Ingress Controller with the new TLS certificate
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Patching the Ingress Controller with the new TLS certificate..."
    ./oc patch ingresscontroller.operator default \
        --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"$SECRET_INGRESS_CUSTOM_TLS\"}}}" \
        -n openshift-ingress-operator \
        || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to patch IngressController(DefaultCertificate)."; exit 1; }

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Successfully executed: $(realpath "$0")"
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Skipped: $(realpath "$0")"
fi