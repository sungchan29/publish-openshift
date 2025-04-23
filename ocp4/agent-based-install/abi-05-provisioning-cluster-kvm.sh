#!/bin/bash

### Enable strict mode
set -euo pipefail

### Get current script name
script_name=$(basename "$0")

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Define variables
VM_NETWORK_01="bridge=bridge0,model=virtio"
VM_IMAGES_PATH="/var/lib/libvirt/images"
RHCOS_AGENT_ISO_FILE="/var/lib/libvirt/images/${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"
ISO_FILE="${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"
SSH_USER="${SSH_USER:-root}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

VM_INFO_LIST="\
thinkstation--master01--8--16384 \
thinkstation--master02--8--16384 \
thinkstation--master03--8--16384 \
localhost--infra01--8--8192 \
localhost--infra02--8--8192 \
localhost--worker01--8--8192 \
"

### Validate source ISO file
echo "[INFO] Checking source ISO file: $ISO_FILE..."
if [[ ! -f "$ISO_FILE" ]]; then
    echo "[ERROR] Source ISO file $ISO_FILE does not exist. Exiting..."
    exit 1
fi

### Extract unique hosts
echo "[INFO] Extracting unique hosts from VM_INFO_LIST..."
hosts=$(echo "$VM_INFO_LIST" | tr -s ' ' '\n' | awk -F "--" '{print $1}' | sort -u)
if [[ -z "$hosts" ]]; then
    echo "[ERROR] No hosts found in VM_INFO_LIST. Exiting..."
    exit 1
fi

### Prepare ISO files on each hypervisor
for host in $hosts; do
    echo "[INFO] Processing hypervisor: $host..."

    if [[ "$host" == "localhost" ]]; then
        qemu_connect="qemu:///system"

        # List directory
        echo "[INFO] Listing directory on $host: $VM_IMAGES_PATH..."
        ls -al "$VM_IMAGES_PATH"
        echo ""

        # Remove existing ISO
        if [[ -f "$VM_IMAGES_PATH/$ISO_FILE" ]]; then
            echo "[INFO] Removing existing ISO on $host: $VM_IMAGES_PATH/$ISO_FILE..."
            rm -f "$VM_IMAGES_PATH/$ISO_FILE"
            echo ""

            echo "[INFO] Listing directory on $host: $VM_IMAGES_PATH..."
            ls -al "$VM_IMAGES_PATH"
            echo ""
        fi

        # Copy new ISO
        echo "[INFO] Copying ISO to $host: $VM_IMAGES_PATH..."
        if ! cp "$ISO_FILE" "$VM_IMAGES_PATH/"; then
            echo "[ERROR] Failed to copy ISO to $VM_IMAGES_PATH on $host. Exiting..."
            exit 1
        fi
        echo "[INFO] Successfully copied ISO to $VM_IMAGES_PATH on $host."
    else
        qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"

        # Test SSH connection
        echo "[INFO] Testing SSH connection to $host..."
        if ! ssh $SSH_OPTIONS "$SSH_USER@$host" exit 2>/dev/null; then
            echo "[ERROR] Failed to connect to $host via SSH. Exiting..."
            exit 1
        fi

        # Test libvirt connection
        echo "[INFO] Testing libvirt connection to $qemu_connect..."
        if ! virsh -c "$qemu_connect" list >/dev/null 2>&1; then
            echo "[ERROR] Failed to connect to libvirt on $qemu_connect. Ensure libvirtd is running and accessible. Exiting..."
            exit 1
        fi

        # List directory
        echo "[INFO] Listing directory on $host: $VM_IMAGES_PATH..."
        ssh $SSH_OPTIONS "$SSH_USER@$host" "ls -al $VM_IMAGES_PATH"
        echo ""

        # Remove existing ISO
        if ssh $SSH_OPTIONS "$SSH_USER@$host" "[[ -f $VM_IMAGES_PATH/$ISO_FILE ]]"; then
            echo "[INFO] Removing existing ISO on $host: $VM_IMAGES_PATH/$ISO_FILE..."
            ssh $SSH_OPTIONS "$SSH_USER@$host" "rm -f $VM_IMAGES_PATH/$ISO_FILE"
            echo ""

            echo "[INFO] Listing directory on $host: $VM_IMAGES_PATH..."
            ssh $SSH_OPTIONS "$SSH_USER@$host" "ls -al $VM_IMAGES_PATH"
            echo ""
        fi

        # Copy new ISO
        echo "[INFO] Copying ISO to $host: $VM_IMAGES_PATH..."
        if ! scp $SSH_OPTIONS "$ISO_FILE" "$SSH_USER@$host:$VM_IMAGES_PATH/"; then
            echo "[ERROR] Failed to copy ISO to $host:$VM_IMAGES_PATH. Exiting..."
            exit 1
        fi
        echo "[INFO] Successfully copied ISO to $VM_IMAGES_PATH on $host."
    fi
    echo "[INFO] Using QEMU connection: $qemu_connect for hypervisor $host."
done

### Validate required variables
echo "[INFO] Starting validation of required variables for $script_name..."
unset required_vars
declare -a required_vars=("CLUSTER_NAME" "OCP_VERSION")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "[ERROR] $var is not defined or empty. Exiting..."
        exit 1
    fi
done
echo "[INFO] Successfully validated required variables."

### Validate directories and files
echo "[INFO] Checking directories and files..."
if [[ ! -d "$VM_IMAGES_PATH" ]]; then
    echo "[ERROR] Directory $VM_IMAGES_PATH does not exist. Exiting..."
    exit 1
fi
if [[ ! -f "$RHCOS_AGENT_ISO_FILE" ]]; then
    echo "[ERROR] ISO file $RHCOS_AGENT_ISO_FILE does not exist. Exiting..."
    exit 1
fi
echo "[INFO] Successfully validated directories and files."

### Validate list sizes
echo "[INFO] Validating list sizes..."
node_count=$(echo "$NODE_INFO_LIST" | tr -s ' ' '\n' | wc -l)
vm_count=$(echo "$VM_INFO_LIST" | tr -s ' ' '\n' | wc -l)
if [[ $node_count -ne $vm_count ]]; then
    echo "[ERROR] Mismatch in list sizes: NODE_INFO_LIST ($node_count), VM_INFO_LIST ($vm_count). Exiting..."
    exit 1
fi
echo "[INFO] Validated list sizes: NODE_INFO_LIST ($node_count), VM_INFO_LIST ($vm_count)."

### Validate names
echo "[INFO] Validating names..."
node_names=$(echo "$NODE_INFO_LIST" | tr -s ' ' '\n' | awk -F "--" '{print $2}' | sort)
vm_names=$(echo "$VM_INFO_LIST" | tr -s ' ' '\n' | awk -F "--" '{print $2}' | sort)
if [[ "$node_names" != "$vm_names" ]]; then
    echo "[ERROR] Name mismatch: VM names ($(echo "$vm_names" | tr '\n' ' ')) do not match NODE_INFO_LIST names ($(echo "$node_names" | tr '\n' ' ')). Exiting..."
    exit 1
fi
echo "[INFO] Validated names: all VM names match NODE_INFO_LIST names."

### Create VMs
echo "[INFO] Starting VM creation for $script_name..."
for host in $hosts; do
    if [[ "$host" == "localhost" ]]; then
        qemu_connect="qemu:///system"
    else
        qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"
    fi

    vm_entries=$(echo "$VM_INFO_LIST" | tr -s ' ' '\n' | grep "^${host}--")
    if [[ -z "$vm_entries" ]]; then
        echo "[WARNING] No VMs found for hypervisor $host. Skipping..."
        continue
    fi

    for vminfo in $vm_entries; do
        HOST=$(echo "$vminfo" | awk -F "--" '{print $1}')
        NAME=$(echo "$vminfo" | awk -F "--" '{print $2}')
        CPU=$(echo "$vminfo" | awk -F "--" '{print $3}')
        MEMORY=$(echo "$vminfo" | awk -F "--" '{print $4}')

        ### Retrieve MAC address from NODE_INFO_LIST
        echo "[INFO] Retrieving MAC address for VM $NAME..."
        mac_address=$(echo "$NODE_INFO_LIST" | tr -s ' ' '\n' | grep -- "--${NAME}--" | awk -F "--" '{print $4}')
        if [[ -z "$mac_address" ]]; then
            echo "[ERROR] No MAC address found for VM $NAME in NODE_INFO_LIST. Exiting..."
            exit 1
        fi
        if [[ ! "$mac_address" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]; then
            echo "[ERROR] Invalid MAC address format: $mac_address for VM $NAME. Exiting..."
            exit 1
        fi
        echo "[INFO] Retrieved MAC address $mac_address for VM $NAME."

        ### Create VM
        echo "[INFO] Creating VM $NAME with connect=$qemu_connect, CPU=$CPU, MEMORY=$MEMORY, MAC=$mac_address..."
        virt-install \
            --connect "${qemu_connect}" \
            --name "${NAME}" \
            --cpu host \
            --vcpus "${CPU}" \
            --memory "${MEMORY}" \
            --disk "${VM_IMAGES_PATH}/${NAME}-01.qcow2,size=100,bus=virtio" \
            --cdrom "${RHCOS_AGENT_ISO_FILE}" \
            --network "${VM_NETWORK_01},mac=${mac_address}" \
            --boot hd \
            --os-variant rhel9-unknown \
            --noautoconsole \
            --wait \
            2>&1 &
        echo ""
    done
done