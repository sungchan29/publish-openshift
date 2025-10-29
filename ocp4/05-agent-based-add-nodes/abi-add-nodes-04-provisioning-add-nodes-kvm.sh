#!/bin/bash

### ---------------------------------------------------------------------------------
### Provision Virtual Machines
### ---------------------------------------------------------------------------------
### This script automates the provisioning of virtual machines (VMs) for an OpenShift
### Agent-Based Installation using 'virt-install'.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### Set the user for remote SSH connections.
SSH_USER="$USER"

### Defines the list of VMs to be provisioned.
### Format: host--name--cpu--memory(MB)--root_disk(GB)--add_disk(GB)
### NOTE: The second list below overwrites the first. Edit as needed for your environment.
VM_INFO_LIST=(
    "thinkstation--ifr03--8--8192--100--0"
        "thinkpad--wrk01--8--8192--100--0"
    "thinkstation--wrk02--8--8192--100--0"
)

iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_nodes.x86_64.iso"

######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### ---------------------------------------------------------------------------------
### Network Bridge Functions
### ---------------------------------------------------------------------------------
### Calculates the maximum number of network interfaces required by any single node in NODE_INFO_LIST.
get_max_interfaces() {
    local max_interfaces=0
    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        local fields; IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local i=1
        while true; do
            local offset=$(( (i-1)*7 + 2 )); local interface_name="${fields[$offset]:-}"
            [[ -z "$interface_name" ]] && break
            i=$((i + 1))
        done
        local num_interfaces=$((i - 1))
        [[ $num_interfaces -gt $max_interfaces ]] && max_interfaces=$num_interfaces
    done
    echo "$max_interfaces"
}

### Discovers available network bridges on a given host (local or remote via SSH).
get_bridge_names() {
    local host="$1"; local bridges=()
    local cmd="nmcli -t -f NAME,TYPE connection show | grep ':bridge$' | grep -v -E 'podman|virbr' | cut -d':' -f1"
    if [[ "$host" == "localhost" ]]; then
        mapfile -t bridges < <(eval "$cmd" 2>/dev/null)
    else
        mapfile -t bridges < <(ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null)
    fi
    echo "${bridges[@]}"
}

### Validates that a specific network bridge exists on a given host.
validate_bridge() {
    local host="$1"; local bridge="$2"
    local cmd="nmcli -t -f NAME,TYPE connection show | grep -q '^$bridge:bridge$'"
    if [[ "$host" == "localhost" ]]; then
        if ! eval "$cmd" 2>/dev/null; then
            printf "%-8s%-80s\n" "[ERROR]" "Bridge '$bridge' not found on localhost. Please create it first. Exiting..."
            exit 1
        fi
    else
        if ! ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null; then
            printf "%-8s%-80s\n" "[ERROR]" "Bridge '$bridge' not found on remote host '$host'. Please create it first. Exiting..."
            exit 1
        fi
    fi
}

### Retrieves the network interface configurations (bridge and MAC address) for a specific VM name.
get_node_interfaces() {
    local vmname="$1"; local interfaces=(); local found=false
    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        local fields; IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local entry_hostname="${fields[1]:-}"
        if [[ "$entry_hostname" == "$vmname" ]]; then
            found=true; local i=1
            while true; do
                local offset=$(( (i-1)*7 + 2 )); local interface_name="${fields[$offset]:-}"; local mac_address="${fields[$((offset+1))]:-}"
                if [[ -z "$interface_name" ]]; then
                    [[ $i -eq 1 ]] && { printf "%-8s%-80s\n" "[ERROR]" "At least one interface is required for node: '$nodeinfo'. Exiting..."; exit 1; }
                    break
                fi
                local bridge_index=$(( (i-1) % ${#network_bridges[@]} )); local bridge="${network_bridges[$bridge_index]}"
                interfaces+=("$bridge:$mac_address")
                i=$((i + 1))
            done
            break
        fi
    done
    if [[ "$found" == false ]]; then printf "%-8s%-80s\n" "[ERROR]" "No node information found for vmname '$vmname' in NODE_INFO_LIST. Exiting..."; exit 1; fi
    if [[ ${#interfaces[@]} -eq 0 ]]; then printf "%-8s%-80s\n" "[ERROR]" "No valid interfaces found for vmname '$vmname' in NODE_INFO_LIST. Exiting..."; exit 1; fi
    echo "${interfaces[@]}"
}

### ---------------------------------------------------------------------------------
### Process VM Provisioning
### ---------------------------------------------------------------------------------
### Calculate the maximum number of network interfaces needed across all nodes.
printf "%-8s%-80s\n" "[INFO]" "Calculating network interface requirements..."
max_interfaces=$(get_max_interfaces)
if [[ $max_interfaces -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "No interfaces found in NODE_INFO_LIST. Please configure at least one. Exiting..."
    exit 1
fi
printf "%-8s%-80s\n" "[INFO]" "Maximum number of interfaces required per node is: $max_interfaces."

### Extract unique KVM hostnames from the VM_INFO_LIST.
declare -A unique_hosts=()
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    if [[ -z "$host" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Invalid VM_INFO_LIST entry: '$vminfo'. Host field is missing. Exiting..."
        exit 1
    fi
    unique_hosts["$host"]=1
done

### Discover and validate network bridges on each unique KVM host.
declare -A host_bridges=()
echo ""
printf "%-8s%-80s\n" "[INFO]" "--- Discovering and validating network bridges on all hosts ---"
for host in "${!unique_hosts[@]}"; do
    bridges=($(get_bridge_names "$host"))
    if [[ ${#bridges[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[WARN]" "No valid network bridges found on '$host'. Falling back to default names (br0, br1, etc.)." >&2
        bridges=(); for ((i=0; i<max_interfaces; i++)); do bridges+=("br$i"); done
    elif [[ ${#bridges[@]} -lt $max_interfaces ]]; then
        printf "%-8s%-80s\n" "[WARN]" "Only ${#bridges[@]} bridge(s) found on '$host', but $max_interfaces are required. Using fallback names." >&2
        bridges=(); for ((i=0; i<max_interfaces; i++)); do bridges+=("br$i"); done
    fi
    host_bridges["$host"]="${bridges[*]}"
    printf "%-8s%-80s\n" "[INFO]" "Bridges configured for '$host': ${bridges[*]}"
done

### Set the primary network bridges that will be used for all VMs.
network_bridges=()
if [[ -n "${host_bridges[localhost]:-}" ]]; then
    IFS=' ' read -r -a network_bridges <<< "${host_bridges[localhost]}"
else
    for host in "${!host_bridges[@]}"; do IFS=' ' read -r -a network_bridges <<< "${host_bridges[$host]}"; break; done
fi
printf "%-8s%-80s\n" "[INFO]" "The following primary network bridges will be used for all VMs: ${network_bridges[*]}"

### Define paths for the Agent ISO file.
virt_dir="/var/lib/libvirt/images"
iso_file="${iso_file:-${CLUSTER_NAME}-v${OCP_VERSION}_nodes.x86_64.iso}"

### Validate that the Agent ISO file exists.
echo ""
printf "%-8s%-80s\n" "[INFO]" "Validating Agent ISO file: '$iso_file'..."
if [[ ! -f "$iso_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Agent ISO file '$iso_file' not found. Please run the ISO generation script first. Exiting..."
    exit 1
fi
printf "%-8s%-80s\n" "[INFO]" "Agent ISO file found."

### Copy the Agent ISO file to each KVM host's libvirt images directory.
echo ""
printf "%-8s%-80s\n" "[INFO]" "--- Copying Agent ISO file to all KVM hosts ---"
for host in "${!unique_hosts[@]}"; do
    if [[ "$host" == "localhost" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "Copying ISO to localhost at '$virt_dir/$iso_file'..."
        mkdir -p "$virt_dir" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to create directory '$virt_dir' on localhost. Exiting..."; exit 1; }
        cp "$iso_file" "$virt_dir/$iso_file" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to copy ISO to '$virt_dir/$iso_file' on localhost. Exiting..."; exit 1; }
    else
        printf "%-8s%-80s\n" "[INFO]" "Copying ISO to remote host '$host' at '$virt_dir/$iso_file'..."
        ssh "${SSH_USER}@${host}" "mkdir -p $virt_dir" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to create directory '$virt_dir' on '$host'. Exiting..."; exit 1; }
        scp "$iso_file" "${SSH_USER}@${host}:$virt_dir/$iso_file" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to copy ISO to '$virt_dir/$iso_file' on '$host'. Exiting..."; exit 1; }
    fi
done
printf "%-8s%-80s\n" "[INFO]" "Agent ISO file successfully copied to all hosts."

### Process each entry in VM_INFO_LIST to provision a VM.
echo ""
printf "%-8s%-80s\n" "[INFO]" "--- Starting VM provisioning for all nodes ---"
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    ### Parse VM details from the configuration string.
    host=$(          echo "$vminfo" | awk -F'--' '{print $1}')
    vmname=$(        echo "$vminfo" | awk -F'--' '{print $2}')
    cpu=$(           echo "$vminfo" | awk -F'--' '{print $3}')
    mem=$(           echo "$vminfo" | awk -F'--' '{print $4}')
    root_disk_size=$(echo "$vminfo" | awk -F'--' '{print $5}')
    add_disk_size=$( echo "$vminfo" | awk -F'--' '{print $6}')

    echo ""
    printf "%-8s%-80s\n" "[INFO]" "Processing VM '$vmname' on host '$host'..."

    ### Validate that all required VM parameters are present.
    if [[ -z "$host" || -z "$vmname" || -z "$cpu" || -z "$mem" || -z "$root_disk_size" || -z "$add_disk_size" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Invalid VM_INFO_LIST entry: '$vminfo'. A required field is missing. Exiting..."
        exit 1
    fi
    if [[ -n "${ADD_DEVICE_NAME:-}" && "$ROOT_DEVICE_NAME" != "$ADD_DEVICE_NAME" && "$add_disk_size" -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "Configuration error for VM '$vmname': ADD_DEVICE_NAME is set but add_disk_size is 0. Exiting..."
        exit 1
    fi

    ### Get the network interface configuration for the current VM.
    interfaces=($(get_node_interfaces "$vmname"))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "No network interfaces found for VM '$vmname' in NODE_INFO_LIST. Exiting..."
        exit 1
    fi

    ### Build the network options for the virt-install command.
    network_options=()
    for iface in "${interfaces[@]}"; do
        IFS=':' read -r bridge mac <<< "$iface"
        network_options+=("--network bridge=$bridge,mac=$mac")
    done

    ### Define disk paths.
    root_disk_path="$virt_dir/${vmname}_root.qcow2"
    if [[ "$add_disk_size" -gt 0 ]]; then
        add_disk_path="$virt_dir/${vmname}_add.qcow2"
    else
        add_disk_path=""
    fi

    ### Set the QEMU connection string for local or remote hosts.
    if [[ "$host" == "localhost" ]]; then
        qemu_connect="qemu:///system"
    else
        qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"
    fi

    ### Build the full 'virt-install' command array.
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

    ### Execute 'virt-install' on the target KVM host in the background.
    printf "%-8s%-80s\n" "[INFO]" "Creating VM '$vmname' on host '$host'..."
    virt_install_cmd_string="${virt_install_cmd[*]} 2>&1 &"
    printf "%-8s%-80s\n" "[INFO]" "Executing command: $virt_install_cmd_string"
    if ! eval "$virt_install_cmd_string"; then
        printf "%-8s%-80s\n" "[ERROR]" "Failed to start the virt-install process for '$vmname' on host '$host'. Exiting..."
        exit 1
    fi
done
echo ""