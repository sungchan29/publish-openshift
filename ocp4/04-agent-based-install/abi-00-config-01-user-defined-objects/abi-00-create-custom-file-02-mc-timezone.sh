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
### Custom Timezone
###   https://access.redhat.com/solutions/5487331
###
for role in "master" "worker"; do
    cat << EOF > $BUTANE_BU_DIR/99-${role}-timezone.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-set-timezone
  labels:
    machineconfiguration.openshift.io/role: ${role}
systemd:
  units:
  - contents: |
      [Unit]
      Description=set timezone
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=timedatectl set-timezone Asia/Seoul

      [Install]
      WantedBy=multi-user.target
    enabled: true
    name: set-timezone.service
EOF
    ./butane $BUTANE_BU_DIR/99-${role}-timezone.bu -o $ADDITIONAL_MANIFEST/99-${role}-timezone.yaml
done