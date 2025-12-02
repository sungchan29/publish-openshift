#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Ingress TLS and Custom CA
### ---------------------------------------------------------------------------------
### ... (주석은 동일) ...

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Apply Ingress TLS and Custom CA Configuration
### ---------------------------------------------------------------------------------
if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Applying Ingress TLS and Custom CA Configuration"

    ### 1. Create a ConfigMap containing the custom root CA certificate.
    printf "%-12s%-80s\n" "[INFO]" "-- Creating ConfigMap 'custom-ingress-root-ca'..."
    ./oc create configmap custom-ingress-root-ca \
        --from-file=ca-bundle.crt="$CUSTOM_ROOT_CA_FILE" \
        -n openshift-config --dry-run=client -o yaml | ./oc apply -f - > /dev/null

    ### 2. Patch the cluster-wide proxy to trust the new root CA from the ConfigMap.
    printf "%-12s%-80s\n" "[INFO]" "-- Patching cluster-wide proxy to trust the custom CA..."
    ./oc patch proxy/cluster \
        --type=merge \
        --patch "{\"spec\":{\"trustedCA\":{\"name\":\"custom-ingress-root-ca\"}}}" > /dev/null

    ### 3. Create a Secret with the wildcard certificate and key for the Ingress Controller.
    printf "%-12s%-80s\n" "[INFO]" "-- Creating Secret 'custom-ingress-default'..."
    ./oc create secret tls custom-ingress-default \
        --key="$INGRESS_CUSTOM_TLS_KEY_FILE" --cert="$INGRESS_CUSTOM_TLS_CRT_FILE" \
        -n openshift-ingress --dry-run=client -o yaml | ./oc apply -f - > /dev/null

    ### 4. Update the Ingress Controller to use the new TLS certificate Secret.
    printf "%-12s%-80s\n" "[INFO]" "-- Patching IngressController 'default' to use the custom certificate..."
    ./oc patch ingresscontroller.operator default \
        --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"custom-ingress-default\"}}}" \
        -n openshift-ingress-operator > /dev/null
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping Ingress TLS and Custom CA configuration. Reason: One or more required files were not found."
    printf "%-12s%-80s\n" "[INFO]" "Checked for the following files:"
    printf "%-12s%-80s\n" "[INFO]" "- CA Cert : $CUSTOM_ROOT_CA_FILE"
    printf "%-12s%-80s\n" "[INFO]" "- TLS Key : $INGRESS_CUSTOM_TLS_KEY_FILE"
    printf "%-12s%-80s\n" "[INFO]" "- TLS Cert: $INGRESS_CUSTOM_TLS_CRT_FILE"
fi