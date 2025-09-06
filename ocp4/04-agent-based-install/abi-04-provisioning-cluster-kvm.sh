#!/bin/bash

### ---------------------------------------------------------------------------------
### Provision Virtual Machines
### ---------------------------------------------------------------------------------
### This script automates the provisioning of virtual machines for an OpenShift
### Agent-Based Installation using 'virt-install'.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Define VM List
### ---------------------------------------------------------------------------------
### Source the configuration file to load all necessary variables and functions.
CONFIG_FILE="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: The configuration file '$CONFIG_FILE' could not be found. Exiting." >&2
    exit 1
fi
if ! source "$CONFIG_FILE"; then
    echo "ERROR: Failed to source '$CONFIG_FILE'. Check file syntax or permissions." >&2
    exit 1
fi

### Set SSH_USER to the current user for remote connections.
SSH_USER="$USER"

### Define a list of VMs to be provisioned.
### The format is: host--name--cpu--memory(M)--root_disk_size(G)--add_disk_size(G)
VM_INFO_LIST=(
    "localhost--sno--32--32768--100--0"
)

VM_INFO_LIST=(
    "thinkstation--mst01--8--16384--100--0"
    "thinkstation--mst02--8--16384--100--0"
    "thinkstation--mst03--8--16384--100--0"
    "thinkstation--ifr01--8--8192--100--0"
    "localhost--ifr02--8--8192--100--0"
)

### ---------------------------------------------------------------------------------
### Network Bridge Functions
### ---------------------------------------------------------------------------------
### Function to calculate maximum number of interfaces across all nodes.
get_max_interfaces() {
    local max_interfaces=0
    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        local fields
        IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local i=1
        while true; do
            local offset=$(( (i-1)*7 + 2 ))
            local interface_name="${fields[$offset]:-}"
            [[ -z "$interface_name" ]] && break
            i=$((i + 1))
        done
        local num_interfaces=$((i - 1))
        [[ $num_interfaces -gt $max_interfaces ]] && max_interfaces=$num_interfaces
    done
    echo "$max_interfaces"
}

### Function to get network bridge names from a host.
get_bridge_names() {
    local host="$1"
    local bridges=()
    local cmd="nmcli -t -f NAME,TYPE connection show | grep ':bridge$' | grep -v -E 'podman|virbr' | cut -d':' -f1"
    if [[ "$host" == "localhost" ]]; then
        mapfile -t bridges < <(eval "$cmd" 2>/dev/null)
    else
        mapfile -t bridges < <(ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null)
    fi
    echo "${bridges[@]}"
}

### Function to validate a network bridge's existence on a host.
validate_bridge() {
    local host="$1"
    local bridge="$2"
    local cmd="nmcli -t -f NAME,TYPE connection show | grep -q '^$bridge:bridge$'"
    if [[ "$host" == "localhost" ]]; then
        if ! eval "$cmd" 2>/dev/null; then
            echo "ERROR: Bridge '$bridge' not found on localhost. Please create it with 'nmcli connection add type bridge ifname $bridge con-name $bridge'." >&2
            exit 1
        fi
    else
        if ! ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null; then
            echo "ERROR: Bridge '$bridge' not found on $host. Please create it." >&2
            exit 1
        fi
    fi
}

### Function to get a VM's network interfaces and map them to bridges.
get_node_interfaces() {
    local vmname="$1"
    local interfaces=()
    local found=false
    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        local fields
        IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local entry_hostname="${fields[1]:-}"
        if [[ "$entry_hostname" == "$vmname" ]]; then
            found=true
            local i=1
            while true; do
                local offset=$(( (i-1)*7 + 2 ))
                local interface_name="${fields[$offset]:-}"
                local mac_address="${fields[$((offset+1))]:-}"
                if [[ -z "$interface_name" ]]; then
                    [[ $i -eq 1 ]] && {
                        echo "ERROR: At least one interface is required for node: $nodeinfo." >&2
                        exit 1
                    }
                    break
                fi
                local bridge_index=$(( (i-1) % ${#NETWORK_BRIDGES[@]} ))
                local bridge="${NETWORK_BRIDGES[$bridge_index]}"
                interfaces+=("$bridge:$mac_address")
                i=$((i + 1))
            done
            break
        fi
    done
    if [[ "$found" == false ]]; then
        echo "ERROR: No node information found for vmname '$vmname' in NODE_INFO_LIST." >&2
        exit 1
    fi
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "ERROR: No valid interfaces found for vmname '$vmname' in NODE_INFO_LIST." >&2
        exit 1
    fi
    echo "${interfaces[@]}"
}

### ---------------------------------------------------------------------------------
### Process VM Provisioning
### ---------------------------------------------------------------------------------
### Calculate the maximum number of interfaces needed.
echo "INFO: Calculating network interface requirements..."
max_interfaces=$(get_max_interfaces)
if [[ $max_interfaces -eq 0 ]]; then
    echo "ERROR: No interfaces found in NODE_INFO_LIST. Please configure at least one." >&2
    exit 1
fi
echo "INFO: Maximum number of interfaces required per node is: $max_interfaces."

### Extract unique hosts from VM_INFO_LIST.
declare -A unique_hosts
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    if [[ -z "$host" ]]; then
        echo "ERROR: Invalid VM_INFO_LIST entry: '$vminfo'. Missing host field." >&2
        exit 1
    fi
    unique_hosts["$host"]=1
done

### Get bridges for each host and validate them.
declare -A host_bridges
echo "INFO: Discovering and validating network bridges on all hosts..."
for host in "${!unique_hosts[@]}"; do
    bridges=($(get_bridge_names "$host"))
    if [[ ${#bridges[@]} -eq 0 ]]; then
        echo "WARNING: No valid bridge connections found on '$host'. Falling back to default bridge names (br0, br1, etc)." >&2
        bridges=()
        for ((i=0; i<max_interfaces; i++)); do
            bridges+=("br$i")
        done
    elif [[ ${#bridges[@]} -lt $max_interfaces ]]; then
        echo "WARNING: Only ${#bridges[@]} bridge(s) found on '$host', but $max_interfaces are required. Using existing bridges and falling back to default names for the rest." >&2
        bridges=()
        for ((i=0; i<max_interfaces; i++)); do
            bridges+=("br$i")
        done
    fi
    host_bridges["$host"]="${bridges[*]}"
    echo "INFO: Bridges configured for '$host': ${bridges[*]}"
done

### Set the primary network bridges to use.
NETWORK_BRIDGES=()
if [[ -n "${host_bridges[localhost]}" ]]; then
    IFS=' ' read -r -a NETWORK_BRIDGES <<< "${host_bridges[localhost]}"
else
    for host in "${!host_bridges[@]}"; do
        IFS=' ' read -r -a NETWORK_BRIDGES <<< "${host_bridges[$host]}"
        break
    done
fi
echo "INFO: The following network bridges will be used for all VMs: ${NETWORK_BRIDGES[*]}"

### ISO paths
virt_dir="/var/lib/libvirt/images"
iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"

### Validate ISO file.
echo "INFO: Validating ISO file: '$iso_file'..."
if [[ ! -f "$iso_file" ]]; then
    echo "ERROR: The ISO file '$iso_file' does not exist. Please run the previous script to generate it." >&2
    exit 1
fi
echo "INFO: ISO file found."

### Copy ISO file to each host's libvirt images directory.
echo "--- Copying ISO file to all hosts..."
for host in "${!unique_hosts[@]}"; do
    if [[ "$host" == "localhost" ]]; then
        echo "INFO: Copying ISO to localhost at '$virt_dir/$iso_file'..."
        mkdir -p "$virt_dir" || {
            echo "ERROR: Failed to create directory '$virt_dir' on localhost." >&2
            exit 1
        }
        cp "$iso_file" "$virt_dir/$iso_file" || {
            echo "ERROR: Failed to copy ISO to '$virt_dir/$iso_file' on localhost." >&2
            exit 1
        }
    else
        echo "INFO: Copying ISO to remote host '$host' at '$virt_dir/$iso_file'..."
        ssh "${SSH_USER}@${host}" "mkdir -p $virt_dir" || {
            echo "ERROR: Failed to create directory '$virt_dir' on '$host'." >&2
            exit 1
        }
        scp "$iso_file" "${SSH_USER}@${host}:$virt_dir/$iso_file" || {
            echo "ERROR: Failed to copy ISO to '$virt_dir/$iso_file' on '$host'." >&2
            exit 1
        }
    fi
done
echo "INFO: ISO file successfully copied to all hosts."

### Process each VM to create it.
echo "--- Starting VM provisioning for all nodes..."
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    ### Parse VM_INFO_LIST entry.
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    vmname=$(echo "$vminfo" | awk -F'--' '{print $2}')
    cpu=$(echo "$vminfo" | awk -F'--' '{print $3}')
    mem=$(echo "$vminfo" | awk -F'--' '{print $4}')
    root_disk_size=$(echo "$vminfo" | awk -F'--' '{print $5}')
    add_disk_size=$(echo "$vminfo" | awk -F'--' '{print $6}')

    echo "INFO: Processing VM '$vmname' on host '$host'..."

    ### Validate VM parameters.
    if [[ -z "$host" || -z "$vmname" || -z "$cpu" || -z "$mem" || -z "$root_disk_size" || -z "$add_disk_size" ]]; then
        echo "ERROR: Invalid VM_INFO_LIST entry: '$vminfo'. Missing required fields." >&2
        exit 1
    fi

    if [[ -n "$ADD_DEVICE_NAME" && "$ROOT_DEVICE_NAME" != "$ADD_DEVICE_NAME" && "$add_disk_size" -eq 0 ]]; then
        echo "ERROR: ADD_DEVICE_NAME is set but add_disk_size is 0 for VM '$vmname'. Please correct your configuration." >&2
        exit 1
    fi

    ### Get network interfaces for the VM.
    interfaces=($(get_node_interfaces "$vmname"))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "ERROR: No network interfaces found for VM '$vmname'." >&2
        exit 1
    fi

    ### Build 'virt-install' command.
    network_options=()
    for iface in "${interfaces[@]}"; do
        IFS=':' read -r bridge mac <<< "$iface"
        network_options+=("--network bridge=$bridge,mac=$mac")
    done

    root_disk_path="$virt_dir/${vmname}_root.qcow2"
    if [[ "$add_disk_size" -gt 0 ]]; then
        add_disk_path="$virt_dir/${vmname}_add.qcow2"
    else
        add_disk_path=""
    fi

    if [[ "$host" == "localhost" ]]; then
        qemu_connect="qemu:///system"
    else
        qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"
    fi

    ### Build 'virt-install' command.
    virt_install_cmd=(
        "virt-install"
        "--connect $qemu_connect"
        "--name $vmname"
        "--vcpus $cpu"
        "--memory $mem"
        "--os-variant rhel9.0"
        "--disk path=$root_disk_path,size=${root_disk_size},bus=virtio"
    )
    if [[ -n "$add_disk_path" ]]; then
        virt_install_cmd+=("--disk path=$add_disk_path,size=${add_disk_size},bus=virtio")
    fi
    virt_install_cmd+=(
        "${network_options[@]}"
        "--boot hd"
        "--cdrom $virt_dir/$iso_file"
        "--noautoconsole"
        "--wait"
    )

    ### Execute 'virt-install' on the host.
    echo "INFO: Creating VM '$vmname' on host '$host'..."
    virt_install_cmd_string="${virt_install_cmd[*]} 2>&1 &"
    echo "INFO: Executing command: $virt_install_cmd_string"
    if ! eval "$virt_install_cmd_string"; then
        echo "ERROR: Failed to start VM creation process for '$vmname' on host '$host'." >&2
        exit 1
    fi
done
echo "INFO: All VMs are being provisioned in the background. Please wait for the process to complete."
echo "INFO: You can check the status with 'virsh list --all'."