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

butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"

###
###
###

cat <<EOF > "$CUSTOM_CONFIG_DIR/timeout.txt"
export TMOUT=300
EOF

###
###
###
if [[ -f "$CUSTOM_CONFIG_DIR/timeout.txt" ]] && [[ -s "$CUSTOM_CONFIG_DIR/timeout.txt" ]]; then
    for role in "master" "worker"; do
        cat <<EOF > "$BUTANE_BU_DIR/99-${role}-timeout.bu"
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-timeout
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/profile.d/99-timeout.sh
    mode: 0644
    overwrite: true
    contents:
      source: data:text/plain;charset=utf-8;base64,$(base64 -w0 "$CUSTOM_CONFIG_DIR/timeout.txt")
EOF
        if [[ -f "$BUTANE_BU_DIR/99-${role}-timeout.bu" ]]; then
            ./butane "$BUTANE_BU_DIR/99-${role}-timeout.bu" -o "$ADDITIONAL_MANIFEST/99-${role}-timeout.yaml"
        else
            echo "[ERROR] Failed to create Butane configuration for role '$role'."
        fi
    done
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi