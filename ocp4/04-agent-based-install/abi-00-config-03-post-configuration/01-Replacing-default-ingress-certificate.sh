#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

###
### Ingress TLS and Custom CA Configuration
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/security_and_compliance/configuring-certificates#replacing-default-ingress
###
if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
    echo "[INFO] Starting Ingress TLS and Custom CA Configuration..."

    ### Create a config map with the root CA certificate
    echo "[INFO] Create a config map with the root CA certificate"
    ./oc create configmap custom-ingress-root-ca \
        --from-file=ca-bundle.crt="$CUSTOM_ROOT_CA_FILE" \
        -n openshift-config --dry-run=client -o yaml | ./oc apply -f -

    ### Update the cluster-wide proxy configuration
    echo "[INFO] Update the cluster-wide proxy configuration"
    ./oc patch proxy/cluster \
        --type=merge \
        --patch "{\"spec\":{\"trustedCA\":{\"name\":\"custom-ingress-root-ca\"}}}"

    ### Create a secret with the wildcard certificate and key
    echo "[INFO] Create a secret with the wildcard certificate and key"
    ./oc create secret tls custom-ingress-default \
        --key="$INGRESS_CUSTOM_TLS_KEY_FILE" --cert="$INGRESS_CUSTOM_TLS_CRT_FILE" \
        -n openshift-ingress --dry-run=client -o yaml | ./oc apply -f -

    ### Update the Ingress Controller with the new TLS certificate
    echo "[INFO] Update the Ingress Controller with the new TLS certificate"
    ./oc patch ingresscontroller.operator default \
        --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"custom-ingress-default\"}}}" \
        -n openshift-ingress-operator
else
    echo "[INFO] Skipped: $(realpath "$0")"
fi