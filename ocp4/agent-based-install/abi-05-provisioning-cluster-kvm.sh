#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
CONFIG_FILE="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Cannot access '$CONFIG_FILE'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$CONFIG_FILE"; then
    echo "[ERROR] Failed to source '$CONFIG_FILE'. Check file syntax or permissions."
    exit 1
fi

### VM_INFO_LIST definition
### Format: host--name--cpu--memory--root_disk--add_disk
VM_INFO_LIST=(
    "localhost--sno--16--32768--100--30"
)

### Function to extract MAC addresses for a given hostname from NODE_INFO_LIST
get_mac_addresses() {
    local hostname="$1"
    local mac_addresses=()
    local context="Node $hostname"

    for nodeinfo in "${NODE_INFO_LIST[@]}"; do
        local fields
        IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local node_hostname="${fields[1]}"

        if [[ "$node_hostname" == "$hostname" ]]; then
            for ((i=1; i<=NODE_INTERFACE_MAX_NUM; i++)); do
                local offset=$(( (i-1)*7 + 3 ))
                local mac_address="${fields[$offset]:-}"
                if [[ -n "$mac_address" ]]; then
                    validate_mac "mac_address_$i" "$mac_address" "$context"
                    mac_addresses+=("$mac_address")
                else
                    break
                fi
            done
            break
        fi
    done

    if [[ ${#mac_addresses[@]} -eq 0 ]]; then
        echo "[ERROR] No MAC addresses found for hostname '$hostname' in NODE_INFO_LIST. Exiting..."
        exit 1
    fi

    echo "${mac_addresses[@]}"
}

### ISO paths
virt_dir="/var/lib/libvirt/images"
iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"

### Validate ISO file
if [[ ! -f "$iso_file" ]]; then
    echo "[ERROR] ISO file '$iso_file' does not exist. Exiting..."
    exit 1
fi

### Parse VM_INFO_LIST and create VMs
for vm_line in "${VM_INFO_LIST[@]}"; do
    ### Skip empty lines
    [[ -z "$vm_line" ]] && continue

    ### Remove whitespace
    vm_line=$(echo "$vm_line" | tr -d '[:space:]')

    ### Parse VM info
    IFS='|' read -r host vmname cpu memory root_disk add_disk <<< "$(echo "$vm_line" | sed 's/--/|/g')"
    echo "[DEBUG] Parsed VM_INFO_LIST entry: host='$host', vmname='$vmname', cpu='$cpu', memory='$memory', root_disk='$root_disk', add_disk='$add_disk'"

    ### Check if add_disk is required when ADD_DEVICE_NAME is set
    if [[ -n "$ADD_DEVICE_NAME" && "$ROOT_DEVICE_NAME" != "$ADD_DEVICE_NAME" && -z "$add_disk" ]]; then
        echo "[ERROR] ADD_DEVICE_NAME is set but add_disk is empty in VM_INFO_LIST entry: '$vm_line'. Exiting..."
        exit 1
    fi

    ### Set QEMU connection based on host
    if [[ "$host" == "localhost" ]]; then
        qemu_connect="qemu:///system"
    else
        if [[ -z "$SSH_USER" ]]; then
            echo "[ERROR] SSH_USER is not set for remote host '$host'. Exiting..."
            exit 1
        fi
        qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"
    fi

    ### Get MAC addresses for the VM
    read -r -a mac_addresses <<< "$(get_mac_addresses "$vmname")"
    echo "[DEBUG] MAC addresses for '$vmname': ${mac_addresses[*]}"

    ### Prepare network options for virt-install
    network_options=""
    for i in "${!mac_addresses[@]}"; do
        mac="${mac_addresses[$i]}"
        network_options+=" --network bridge=bridge$i,mac=$mac"
    done
    echo "[DEBUG] Network options: $network_options"

    ### Prepare disk options
    disk_options="--disk ${virt_dir}/${vmname}_root.qcow2,size=${root_disk},bus=virtio"
    if [[ -n "$add_disk" && -n "$ADD_DEVICE_NAME" && "$ROOT_DEVICE_NAME" != "$ADD_DEVICE_NAME" ]]; then
        disk_options+=" --disk ${virt_dir}/${vmname}_add.qcow2,size=${add_disk},bus=virtio"
    fi

    ### virt-install Command
    virt_install_cmd="virt-install \
        --connect $qemu_connect \
        --name $vmname \
        --vcpus $cpu \
        --memory $memory \
        $disk_options \
        --cdrom $virt_dir/$iso_file \
        $network_options \
        --os-variant rhel9-unknown \
        --boot hd \
        --noautoconsole \
        --wait \
        2>&1 &"

    ### Copy ISO file to host
    if [[ "$host" == "localhost" ]]; then
        ### Copy ISO file to local host
        echo "[INFO] Checking and copying ISO file to local host '$host'."
        ### Check if the ISO file exists on the local host
        if [[ -f "$virt_dir/$iso_file" ]]; then
            echo "[INFO] ISO file exists on local host '$host'. Deleting it."
            rm -f "$virt_dir/$iso_file" || {
                echo "[ERROR] Failed to delete existing ISO file on local host '$host'. Exiting..."
                exit 1
            }
        fi
        ### List the local directory contents before copying
        echo "[INFO] Listing directory on local host: ls -l $virt_dir"
            ls -l "$virt_dir" || {
            echo "[ERROR] Failed to list directory on local host '$host'. Exiting..."
            exit 1
        }
        ### Copy the ISO file to the local host
        echo "[INFO] Copying ISO file to '$virt_dir' on local host '$host'."
        cp "$iso_file" "$virt_dir/" || {
            echo "[ERROR] Failed to copy ISO file to local host '$host'. Exiting..."
            exit 1
        }
        ### List the local directory contents after copying
        echo "[INFO] Listing directory on local host: ls -l $virt_dir"
        ls -l "$virt_dir" || {
            echo "[ERROR] Failed to list directory on local host '$host'. Exiting..."
            exit 1
        }
        echo "[INFO] ISO file '$iso_file' copied successfully to local host '$host'."
    else
        ### Copy ISO file to remote host via SSH
        echo "[INFO] Checking and copying ISO file to remote host '$host'."
        ### Check if the ISO file exists on the remote host
        if ssh "${SSH_USER}@${host}" "[ -f $virt_dir/$iso_file ]"; then
            echo "[INFO] ISO file exists on remote host '$host'. Deleting it."
            ssh "${SSH_USER}@${host}" "rm -f $virt_dir/$iso_file" || {
                echo "[ERROR] Failed to delete existing ISO file on remote host '$host'. Exiting..."
                exit 1
            }
        fi
        ### List the remote directory contents before copying
        echo "[INFO] Listing directory on remote host: ls -l $virt_dir"
        ssh "${SSH_USER}@${host}" "ls -l $virt_dir" || {
            echo "[ERROR] Failed to list directory on remote host '$host'. Exiting..."
            exit 1
        }
        ### Copy the ISO file to the remote host
        echo "[INFO] Copying ISO file to '$virt_dir' on remote host '$host'."
        scp "$iso_file" "${SSH_USER}@${host}:${virt_dir}/" || {
            echo "[ERROR] Failed to copy ISO file to remote host '$host'. Exiting..."
            exit 1
        }
        ### List the remote directory contents after copying
        echo "[INFO] Listing directory on remote host: ls -l $virt_dir"
        ssh "${SSH_USER}@${host}" "ls -l $virt_dir" || {
            echo "[ERROR] Failed to list directory on remote host '$host'. Exiting..."
            exit 1
        }
        echo "[INFO] ISO file '$iso_file' copied successfully to remote host '$host'."
    fi

    ### Execute command
    echo "[INFO] Creating VM '$vmname' on host '$host' with QEMU connection '$qemu_connect' and MAC addresses: ${mac_addresses[*]}"
    if ! eval "$virt_install_cmd"; then
        echo "[ERROR] Failed to create VM '$vmname' on host '$host'. Exiting..."
        exit 1
    fi
    echo "[INFO] VM '$vmname' creation started successfully."
done
echo "[INFO] All VMs provisioned successfully."