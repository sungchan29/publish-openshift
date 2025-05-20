#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
CONFIG_FILE="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Cannot access '$CONFIG_FILE'. File or directory does not exist. Exiting..." >&2
    exit 1
fi
if ! source "$CONFIG_FILE"; then
    echo "[ERROR] Failed to source '$CONFIG_FILE'. Check file syntax or permissions." >&2
    exit 1
fi

### Set SSH_USER to the current user
SSH_USER="$USER"

### VM_INFO_LIST definition
### Format: host--name--cpu--memory(M)--root_disk_size(G)--add_disk_size(G)
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

### Function to calculate maximum number of interfaces across all nodes
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

### Function to get bridge names from a host using nmcli, excluding podman and virbr
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

### Function to validate bridge existence on a host
validate_bridge() {
    local host="$1"
    local bridge="$2"
    local cmd="nmcli -t -f NAME,TYPE connection show | grep -q '^$bridge:bridge$'"
    if [[ "$host" == "localhost" ]]; then
        if ! eval "$cmd" 2>/dev/null; then
            echo "[ERROR] Bridge '$bridge' not found on localhost. Configure it with 'nmcli connection add type bridge ifname $bridge con-name $bridge' or update network configuration. Exiting..." >&2
            exit 1
        fi
    else
        if ! ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null; then
            echo "[ERROR] Bridge '$bridge' not found on $host. Configure it with 'nmcli connection add type bridge ifname $bridge con-name $bridge' or update network configuration. Exiting..." >&2
            exit 1
        fi
    fi
}

### Generate network bridges
max_interfaces=$(get_max_interfaces)
if [[ $max_interfaces -eq 0 ]]; then
    echo "[ERROR] No interfaces found in NODE_INFO_LIST. Exiting..." >&2
    exit 1
fi

### Extract unique hosts from VM_INFO_LIST
declare -A unique_hosts
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    if [[ -z "$host" ]]; then
        echo "[ERROR] Invalid VM_INFO_LIST entry: '$vminfo'. Missing host field. Exiting..." >&2
        exit 1
    fi
    unique_hosts["$host"]=1
done

### Get bridge names for each host and determine NETWORK_BRIDGES
declare -A host_bridges
for host in "${!unique_hosts[@]}"; do
    bridges=($(get_bridge_names "$host"))
    if [[ ${#bridges[@]} -eq 0 ]]; then
        echo "[WARNING] No valid bridge connections (excluding podman/virbr) found on $host. Falling back to generated bridge names." >&2
        bridges=()
        for ((i=0; i<max_interfaces; i++)); do
            bridges+=("br$i")
        done
    elif [[ ${#bridges[@]} -lt $max_interfaces ]]; then
        echo "[WARNING] Only ${#bridges[@]} bridge(s) found on $host (${bridges[*]}), but $max_interfaces required. Falling back to generated bridge names." >&2
        bridges=()
        for ((i=0; i<max_interfaces; i++)); do
            bridges+=("br$i")
        done
    fi
    host_bridges["$host"]="${bridges[*]}"
    echo "[INFO] Bridges for $host: ${bridges[*]}" >&2
done

### Validate bridges on each host
for host in "${!unique_hosts[@]}"; do
    IFS=' ' read -r -a bridges <<< "${host_bridges[$host]}"
    for bridge in "${bridges[@]}"; do
        validate_bridge "$host" "$bridge"
    done
done

### Set NETWORK_BRIDGES to the union of all host bridges (use localhost as default if available)
NETWORK_BRIDGES=()
if [[ -n "${host_bridges[localhost]}" ]]; then
    IFS=' ' read -r -a NETWORK_BRIDGES <<< "${host_bridges[localhost]}"
else
    # Use the first host's bridges if localhost is not used
    for host in "${!host_bridges[@]}"; do
        IFS=' ' read -r -a NETWORK_BRIDGES <<< "${host_bridges[$host]}"
        break
    done
fi
echo "[INFO] Using NETWORK_BRIDGES: ${NETWORK_BRIDGES[*]}" >&2

### Function to get network interfaces for a node
get_node_interfaces() {
    local vmname="$1"
    local interfaces=()
    local context="Node $vmname"
    local found=false

    echo "[DEBUG] Searching for interfaces for vmname '$vmname' in NODE_INFO_LIST" >&2
    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        echo "[DEBUG] Processing NODE_INFO_LIST entry: $nodeinfo" >&2
        local fields
        IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        local entry_hostname="${fields[1]:-}"

        if [[ "$entry_hostname" == "$vmname" ]]; then
            found=true
            echo "[DEBUG] Found matching hostname '$entry_hostname' for '$vmname'" >&2
            local i=1
            while true; do
                local offset=$(( (i-1)*7 + 2 ))
                local interface_name="${fields[$offset]:-}"
                local mac_address="${fields[$((offset+1))]:-}"
                if [[ -z "$interface_name" ]]; then
                    [[ $i -eq 1 ]] && {
                        echo "[ERROR] At least one interface required for node: $nodeinfo" >&2
                        exit 1
                    }
                    break
                fi
                if validate_mac "mac_address_$i" "$mac_address" "$context"; then
                    if [[ $i -gt ${#NETWORK_BRIDGES[@]} ]]; then
                        echo "[WARNING] Number of interfaces ($i) for node $vmname exceeds available bridges (${#NETWORK_BRIDGES[@]}). Cycling bridges." >&2
                    fi
                    local bridge_index=$(( (i-1) % ${#NETWORK_BRIDGES[@]} ))
                    local bridge="${NETWORK_BRIDGES[$bridge_index]}"
                    interfaces+=("$bridge:$mac_address")
                    echo "[DEBUG] Added interface $i: bridge=$bridge, mac=$mac_address" >&2
                else
                    echo "[WARNING] Skipping invalid MAC address '$mac_address' for interface $i" >&2
                fi
                i=$((i + 1))
            done
            break
        fi
    done

    if [[ "$found" == false ]]; then
        echo "[ERROR] No node information found for vmname '$vmname' in NODE_INFO_LIST. Exiting..." >&2
        exit 1
    fi

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "[ERROR] No valid interfaces found for vmname '$vmname' in NODE_INFO_LIST. Exiting..." >&2
        exit 1
    fi

    echo "${interfaces[@]}"
}

### ISO paths
virt_dir="/var/lib/libvirt/images"
iso_file="${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"

### Validate ISO file
if [[ ! -f "$iso_file" ]]; then
    echo "[ERROR] ISO file '$iso_file' does not exist. Exiting..." >&2
    exit 1
fi

### Copy ISO file to each host
for host in "${!unique_hosts[@]}"; do
    if [[ "$host" == "localhost" ]]; then
        echo "[INFO] Copying ISO to localhost at $virt_dir/$iso_file" >&2
        mkdir -p "$virt_dir" || {
            echo "[ERROR] Failed to create directory $virt_dir on localhost" >&2
            exit 1
        }
        cp "$iso_file" "$virt_dir/$iso_file" || {
            echo "[ERROR] Failed to copy ISO to $virt_dir/$iso_file on localhost" >&2
            exit 1
        }
    else
        echo "[INFO] Copying ISO to $host at $virt_dir/$iso_file" >&2
        ssh "${SSH_USER}@${host}" "mkdir -p $virt_dir" || {
            echo "[ERROR] Failed to create directory $virt_dir on $host" >&2
            exit 1
        }
        scp "$iso_file" "${SSH_USER}@${host}:$virt_dir/$iso_file" || {
            echo "[ERROR] Failed to copy ISO to $virt_dir/$iso_file on $host" >&2
            exit 1
        }
    fi
done

### Process each VM
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    # Parse VM_INFO_LIST entry using awk
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    vmname=$(echo "$vminfo" | awk -F'--' '{print $2}')
    cpu=$(echo "$vminfo" | awk -F'--' '{print $3}')
    mem=$(echo "$vminfo" | awk -F'--' '{print $4}')
    root_disk_size=$(echo "$vminfo" | awk -F'--' '{print $5}')
    add_disk_size=$(echo "$vminfo" | awk -F'--' '{print $6}')
    
    # Debug parsed fields
    echo "[DEBUG] Parsed VM_INFO_LIST entry: host=$host, vmname=$vmname, cpu=$cpu, mem=$mem, root_disk_size=$root_disk_size, add_disk_size=$add_disk_size" >&2
    
    echo "[INFO] Processing VM: $vmname on $host with $cpu vCPUs, ${mem}M memory, ${root_disk_size}G root disk, ${add_disk_size}G additional disk" >&2

    ### Validate VM parameters
    if [[ -z "$host" || -z "$vmname" || -z "$cpu" || -z "$mem" || -z "$root_disk_size" || -z "$add_disk_size" ]]; then
        echo "[ERROR] Invalid VM_INFO_LIST entry: '$vminfo'. Missing required fields. Exiting..." >&2
        exit 1
    fi

    ### Check if add_disk is required when ADD_DEVICE_NAME is set
    if [[ -n "$ADD_DEVICE_NAME" && "$ROOT_DEVICE_NAME" != "$ADD_DEVICE_NAME" && "$add_disk_size" -eq 0 ]]; then
        echo "[ERROR] ADD_DEVICE_NAME is set but add_disk_size is 0 for VM '$vmname'. Exiting..." >&2
        exit 1
    fi

    ### Get network interfaces for the VM
    interfaces=($(get_node_interfaces "$vmname"))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "[ERROR] No network interfaces found for VM $vmname. Exiting..." >&2
        exit 1
    fi

    ### Build network options for virt-install
    network_options=()
    for iface in "${interfaces[@]}"; do
        IFS=':' read -r bridge mac <<< "$iface"
        network_options+=("--network bridge=$bridge,mac=$mac")
    done

    ### Create disk paths
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

    ### Build virt-install command
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

    ### Execute commands on the host
    virt_install_cmd_string="${virt_install_cmd[*]} 2>&1 &"
    echo "[INFO] Running virt-install on localhost: $virt_install_cmd_string" >&2
    ### Execute command
    echo "[INFO] Creating VM '$vmname' on host '$host' with QEMU connection '$qemu_connect' and MAC addresses: ${mac_addresses[*]}"
    if ! eval "$virt_install_cmd_string"; then
        echo "[ERROR] Failed to create VM '$vmname' on host '$host'. Exiting..."
        exit 1
    fi
done

echo "[INFO] All VMs provisioned successfully." >&2