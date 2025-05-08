#!/bin/bash

### Enable strict mode
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

### Config ingress conroller
if [[ -n "$INGRESS_REPLICAS" ]] && [[ -n "$INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY" ]] && [[ -n "$INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY" ]]; then
    cat << EOF > $ADDITIONAL_MANIFEST/ingress-controller.yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  replicas: $INGRESS_REPLICAS
  nodePlacement:
    nodeSelector:
      matchLabels:
        ${INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY}: ""
    tolerations:
    - effect: NoSchedule
      operator: Exists
      key: $INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY
EOF
    if [[ $? -eq 0 ]]; then
        echo "[INFO] Successfully executed : $(dirname "$(realpath "$0")")/$(basename "$0")"
    else
        echo "[ERROR] Failed to patch IngressController(default)."
    fi
else
    echo "[INFO] Skipped               : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi