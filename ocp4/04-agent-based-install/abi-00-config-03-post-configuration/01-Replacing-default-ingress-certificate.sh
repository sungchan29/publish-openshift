#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Ingress TLS and Custom CA
### ---------------------------------------------------------------------------------
### This script applies a custom TLS certificate to the OpenShift Ingress Controller
### and configures the cluster to trust a custom root CA. This is a crucial step
### for disconnected environments that use a private certificate authority.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the main configuration file to load all necessary variables.
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' does not exist. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### Apply Ingress TLS and Custom CA
### Ingress TLS and Custom CA Configuration
###   https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/security_and_compliance/configuring-certificates#replacing-default-ingress
### ---------------------------------------------------------------------------------
### Check for the existence of all required certificate and key files.
if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
    echo "INFO: Required certificate and key files found. Starting Ingress TLS and Custom CA configuration..."

    ### Create a config map with the custom root CA certificate.
    echo "INFO: Creating ConfigMap 'custom-ingress-root-ca' in openshift-config..."
    ./oc create configmap custom-ingress-root-ca \
        --from-file=ca-bundle.crt="$CUSTOM_ROOT_CA_FILE" \
        -n openshift-config --dry-run=client -o yaml | ./oc apply -f -
    echo "INFO: ConfigMap 'custom-ingress-root-ca' created successfully."

    ### Patch the cluster-wide proxy to trust the new root CA.
    echo "INFO: Patching cluster-wide proxy configuration to trust the custom CA..."
    ./oc patch proxy/cluster \
        --type=merge \
        --patch "{\"spec\":{\"trustedCA\":{\"name\":\"custom-ingress-root-ca\"}}}"
    echo "INFO: Cluster-wide proxy updated."

    ### Create a secret with the wildcard certificate and key for the ingress controller.
    echo "INFO: Creating Secret 'custom-ingress-default' in openshift-ingress..."
    ./oc create secret tls custom-ingress-default \
        --key="$INGRESS_CUSTOM_TLS_KEY_FILE" --cert="$INGRESS_CUSTOM_TLS_CRT_FILE" \
        -n openshift-ingress --dry-run=client -o yaml | ./oc apply -f -
    echo "INFO: Secret 'custom-ingress-default' created successfully."

    ### Update the Ingress Controller to use the new TLS certificate.
    echo "INFO: Patching IngressController 'default' to use the custom TLS certificate..."
    ./oc patch ingresscontroller.operator default \
        --type=merge \
        -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"custom-ingress-default\"}}}" \
        -n openshift-ingress-operator
    echo "INFO: Ingress Controller updated. The cluster should now use your custom certificate."

    echo "--- Ingress TLS and Custom CA configuration is complete."
else
    echo "INFO: Skipping Ingress TLS and Custom CA configuration. One or more required files were not found."
    echo "      - Required files:"
    echo "        - $CUSTOM_ROOT_CA_FILE"
    echo "        - $INGRESS_CUSTOM_TLS_KEY_FILE"
    echo "        - $INGRESS_CUSTOM_TLS_CRT_FILE"
    echo "--- Script execution finished without applying changes."
fi