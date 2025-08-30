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

###
###
###
if [[ -n "$NTP_SERVER_01" ]]; then
    butane_ocp_version="$(echo "$OCP_VERSION" | awk '{print $NF}' | sed 's/\.[0-9]*$/\.0/')"
    for role in "master" "worker"; do
        cat << EOF > $BUTANE_BU_DIR/99-${role}-chrony.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-chrony
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/chrony.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        pool $NTP_SERVER_01 iburst
EOF
        if [[ -n $NTP_SERVER_02 ]]; then
            cat << EOF >> $BUTANE_BU_DIR/99-${role}-chrony.bu
        pool $NTP_SERVER_02 iburst
EOF
        fi
        cat << EOF >> $BUTANE_BU_DIR/99-${role}-chrony.bu
        driftfile /var/lib/chrony/drift
        makestep 1.0 3
        rtcsync
        logdir /var/log/chrony
EOF
        ./butane $BUTANE_BU_DIR/99-${role}-chrony.bu -o $ADDITIONAL_MANIFEST/99-${role}-chrony.yaml
    done
else
    echo "[INFO] Skipped : $(dirname "$(realpath "$0")")/$(basename "$0")"
fi