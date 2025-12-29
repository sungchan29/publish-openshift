#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Ingress TLS and Custom CA
### ---------------------------------------------------------------------------------
### This script updates the Ingress Controller certificate.
### It is designed to be executed stand-alone OR via a parent script.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Path & Config Loading
### ---------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
config_file="${ROOT_DIR}/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Config not found: $config_file"
    exit 1
fi
source "$config_file"

### OC Command Check
if [[ -f "${ROOT_DIR}/oc" ]]; then
    OC_CMD="${ROOT_DIR}/oc"
elif command -v oc &> /dev/null; then
    OC_CMD="oc"
else
    printf "%-12s%-80s\n" "[ERROR]" "'oc' binary not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Execution Logic
### ---------------------------------------------------------------------------------
if [[ -f "$CUSTOM_ROOT_CA_FILE" && -f "$INGRESS_CUSTOM_TLS_KEY_FILE" && -f "$INGRESS_CUSTOM_TLS_CRT_FILE" ]]; then
    printf "%-12s%-80s\n" "[INFO]" "Applying Ingress TLS Configuration..."

    ### 1. ConfigMap (Pipe requires eval)
    printf "%-12s%-80s\n" "[INFO]" "-- Configuring ConfigMap 'custom-ingress-root-ca'..."
    CMD_STR="$OC_CMD create configmap custom-ingress-root-ca --from-file=ca-bundle.crt=\"$CUSTOM_ROOT_CA_FILE\" -n openshift-config --dry-run=client -o yaml | $OC_CMD apply -f -"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    eval "$CMD_STR"

    ### 2. Proxy Patch (Direct execution is safer)
    printf "%-12s%-80s\n" "[INFO]" "-- Patching cluster-wide proxy..."
    PROXY_PATCH='{"spec":{"trustedCA":{"name":"custom-ingress-root-ca"}}}'
    CMD_STR="$OC_CMD patch proxy/cluster --type=merge --patch '$PROXY_PATCH'"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    $OC_CMD patch proxy/cluster --type=merge --patch "$PROXY_PATCH"

    ### 3. Secret (Pipe requires eval)
    printf "%-12s%-80s\n" "[INFO]" "-- Configuring Secret 'custom-ingress-default'..."
    CMD_STR="$OC_CMD create secret tls custom-ingress-default --key=\"$INGRESS_CUSTOM_TLS_KEY_FILE\" --cert=\"$INGRESS_CUSTOM_TLS_CRT_FILE\" -n openshift-ingress --dry-run=client -o yaml | $OC_CMD apply -f -"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    eval "$CMD_STR"

    ### 4. Ingress Patch (Direct execution is safer)
    printf "%-12s%-80s\n" "[INFO]" "-- Patching IngressController..."
    INGRESS_PATCH='{"spec":{"defaultCertificate":{"name":"custom-ingress-default"}}}'
    CMD_STR="$OC_CMD patch ingresscontroller.operator default --type=merge -p '$INGRESS_PATCH' -n openshift-ingress-operator"

    printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
    printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
    $OC_CMD patch ingresscontroller.operator default --type=merge -p "$INGRESS_PATCH" -n openshift-ingress-operator

    printf "%-12s%-80s\n" "[INFO]" "SUCCESS: Ingress configuration applied."
else
    printf "%-12s%-80s\n" "[INFO]" "Skipping. Required files not found."
    exit 1
fi