
```bash

mkdir -p $HOME/agent-based-install

cd  $HOME/agent-based-install

vi abi-01-config-preparation-01-general.sh

```

```bash
#!/bin/bash
OCP_VERSION="4.17.3"

DOWNLOAD_DIRECTORY="/root/Downloads/ocp/mirror_workspace/ocp4-install-files-v4.16.7--4.16.19--4.17.3"

### Mirror Registry
MIRROR_REGISTRY_TRUST_FILE="/etc/pki/ca-trust/source/anchors/nexus.cloudpang.tistory.disconnected.pem"
MIRROR_REGISTRY_HOSTNAME="nexus.cloudpang.tistory.disconnected"
MIRROR_REGISTRY_PORT="5000"
MIRROR_REGISTRY_USERNAME="admin"
MIRROR_REGISTRY_PASSWORD="redhat1!"

LOCAL_REPOSITORY_NAME="ocp4/openshift"

OLM_OPERATORS="redhat--certified--community"

###
### agent-config.yaml
###

CLUSTER_NAME="cloudpang"
BASE_DOMAIN="tistory.disconnected"

### Default: cat ~/.ssh/id_ed25519.pub
### https://access.redhat.com/solutions/5638721
### https://access.redhat.com/solutions/3868301
#if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
#  rm -rf ~/.ssh/id_ed25519*
#  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
#fi
#eval "$(ssh-agent -s)"
#ssh-add ~/.ssh/id_ed25519
#SSH_KEY="$(cat ~/.ssh/id_ed25519.pub)"

SSH_KEY_01="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG8qJQJbNWHxvHOMOgtA++F2TdtvYEvrBEWPHkvKg+is root@thinkpad"
SSH_KEY_02="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINw0niln0q4xQVALeSuwjfMvPN4chTNYgHMPVOGgJqfw root@thinkstation"

NTP_SERVER_01="11.119.120.28"
NTP_SERVER_02=""

DNS_SERVER_01="11.119.120.28"
DNS_SERVER_02=""

RENDEZVOUS_IP="11.119.120.111"

# ROLE--HOSTNAME--INTERFACE_01--MAC_01--IP_01--PREFIX_01--DESTINATION_01--NEXT_HOP_01--TABLE_ID_01[--INTERFACE_02--...--TABLE_ID_02][--INTERFACE_03--...--TABLE_ID_03]
NODE_INFO_LIST=" \
  master--sno--enp1s0--52:54:00:7d:e1:09--11.119.120.109--24--0.0.0.0/0--11.119.120.28--254 \
"
#  master--master01--enp1s0--52:54:00:7d:e1:11--11.119.120.111--24--0.0.0.0/0--11.119.120.28--254 \
#  master--master02--enp1s0--52:54:00:7d:e1:12--11.119.120.112--24--0.0.0.0/0--11.119.120.28--254 \
#  master--master03--enp1s0--52:54:00:7d:e1:13--11.119.120.113--24--0.0.0.0/0--11.119.120.28--254 \
#"
#  worker--infra01--enp1s0--52:54:00:7d:e1:21--11.119.120.121--24--0.0.0.0/0--11.119.120.28--254 \
#  worker--infra02--enp1s0--52:54:00:7d:e1:22--11.119.120.122--24--0.0.0.0/0--11.119.120.28--254 \
#  worker--infra03--enp1s0--52:54:00:7d:e1:23--11.119.120.123--24--0.0.0.0/0--11.119.120.28--254 \
#  worker--egress01--enp1s0--52:54:00:7d:e1:24--11.119.120.124--24--0.0.0.0/0--11.119.120.28--254 \
#  worker--egress02--enp1s0--52:54:00:7d:e1:25--11.119.120.125--24--0.0.0.0/0--11.119.120.28--254 \
#"

### role--node_prefix
NODE_ROLE_SELECTORS=" \
infra--infra \
egress--egress \
"

#INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY="node-role.kubernetes.io/infra"
INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY="node-role.kubernetes.io/worker"

###
### Mounting separate disk for OpenShift 4 container storage
### Default value : When there is only one disk, the required values for partition configuration are specified by default.
### by-pass value settings for root device
ROOT_DEVICE_NAME="/dev/disk/by-path/pci-0000:04:00.0"
ADD_DEVICE_NAME=""

# Default: /var/lib/containers
FILESYSTEM_PATH=""

# Default: Do not use partition labels
#          "PARTITION" or ""
ADD_DEVICE_TYPE="PARTITION"

# Add partition or disk
#   ADD_DEVICE_NAME must not be blank
#   If ROOT_DEVICE_NAME = ADD_DEVICE_NAME
#     Detault: 25000
#   If ROOT_DEVICE_NAME != ADD_DEVICE_NAME
#     Detault: 0
ADD_DEVICE_PARTITION_START_MIB=""

###
### install-config.yaml
###

### Machine CIDR ranges cannot be changed after creating your cluster.
### Machine CIDR
MACHINE_NETWORK="11.119.120.0/24"

### Service CIDR
#SERVICE_NETWORK="172.30.0.0/16"
SERVICE_NETWORK="10.1.0.0/21"

### Pod CIDR
#CLUSTER_NETWORK_CIDR="10.128.0.0/14"
CLUSTER_NETWORK_CIDR="10.0.0.0/21"

### Host Prefix
#HOST_PREFIX="23"
HOST_PREFIX="24"

INTERNAL_JOIN_SUBNET="10.1.253.0/23"
INTERNAL_TRANSIT_SWITCH_SUBNET="10.1.255.0/25"
INTERNAL_MASQUERADE_SUBNET="10.1.255.128/29"

VULNERABILITY_MITIGATION_TEXT="./vulnerability-mitigation-text"

#####################
#####################
#####################

MIRROR_REGISTRY="${MIRROR_REGISTRY_HOSTNAME}${MIRROR_REGISTRY_PORT:+:${MIRROR_REGISTRY_PORT}}"

if [[ "$ROOT_DEVICE_NAME" = "$ADD_DEVICE_NAME" ]]; then
    ADD_DEVICE_TYPE="PARTITION"
    PARTITION_START_MIB="${DEVICE_1_PARTITION_START_MIB:-25000}"
    PARTITION_SIZE_MIB="0"
    PARTITION_NUMBER="5"
else
    if [[ "PARTITION" = "$ADD_DEVICE_TYPE" ]]; then
        PARTITION_START_MIB="0"
        PARTITION_SIZE_MIB="0"
        PARTITION_NUMBER="1"
    fi
fi
FILESYSTEM_PATH="${FILESYSTEM_PATH:-"/var/lib/containers"}"
PARTITION_LABEL="${PARTITION_LABEL:-"$(echo $FILESYSTEM_PATH | sed 's#^/##; s#/#-#g')"}"
```