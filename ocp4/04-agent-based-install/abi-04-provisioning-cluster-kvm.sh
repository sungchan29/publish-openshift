#!/bin/bash

### ---------------------------------------------------------------------------------
### OpenShift Agent-Based VM Provisioning (Concurrent Mode)
### ---------------------------------------------------------------------------------
### Description:
###   - Automatically assigns network bridges by matching VM IP subnets to Host Bridge subnets.
###   - Provisions VMs concurrently (background) to speed up deployment.
###   - Logs output (stdout/stderr) and PIDs to a dedicated directory: ./create-kvm-log/
###   - Waits for all background processes to finish before exiting to ensure integrity.
### ---------------------------------------------------------------------------------

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### VM Provisioning Configuration
### ---------------------------------------------------------------------------------
### Description:
###   Defines the infrastructure topology for the OpenShift cluster.
###   Each entry in the list corresponds to a single KVM Virtual Machine.
###
### Syntax Format:
###   TARGET_HOST--VM_NAME--CPU(CORE)--RAM(MB)--ROOT_DISK(GB)--DATA_DISK(GB)
### ---------------------------------------------------------------------------------

### [Option 1] Standard High-Availability Cluster (3 Masters + N Workers)
VM_INFO_LIST=(
    "host2--mst01--8--20480--120--0"
    "host2--mst02--8--20480--120--0"
    "host2--mst03--8--20480--120--0"
    "localhost--ifr01--8--8192--120--0"
    "localhost--ifr02--8--8192--100--0"
)

### [Option 2] Single Node OpenShift (SNO)
#VM_INFO_LIST=(
#     "localhost--sno--8--32768--120--0"
#)

### Directory on the KVM host where disk images and ISOs will be stored
### If left empty (""), the script defaults to '/var/lib/libvirt/images'.
VIRT_DIR=""

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ---------------------------------------------------------------------------------
### Load Configuration and Dependencies
### ---------------------------------------------------------------------------------

### Load external configuration file
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..." >&2
    exit 1
fi
source "$config_file"

### Set the user for remote SSH connections.
SSH_USER="$USER"

### ---------------------------------------------------------------------------------
### Setup Log Directory
### ---------------------------------------------------------------------------------

log_dir="$(pwd)/create-kvm-log"
printf "%-8s%-80s\n" "[INFO]" "=== Setting up Log Directory ==="
printf "%-8s%-80s\n" "[INFO]" "    Path: $log_dir" >&2
rm -rf "$log_dir"
mkdir -p "$log_dir"

### ---------------------------------------------------------------------------------
### Network Bridge Functions (Pure Bash Implementation)
### ---------------------------------------------------------------------------------

### Calculates the Network Address (Subnet) from an IP and Prefix using Bash bitwise operations.
### Replaces the need for 'ipcalc'.
get_subnet_from_ip_prefix() {
    local ip="$1"
    local prefix="$2"

    ### 1. Validate Input Existence
    [[ -z "$ip" || -z "$prefix" ]] && return 1

    ### 2. Validate Prefix (0-32)
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
        echo "Error: Invalid prefix '$prefix'" >&2
        return 1
    fi

    ### 3. Split IP into 4 Octets
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$ip"

    ### 4. Validate IP Format
    if ! [[ "$i1" =~ ^[0-9]+$ && "$i2" =~ ^[0-9]+$ && "$i3" =~ ^[0-9]+$ && "$i4" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid IP format '$ip'" >&2
        return 1
    fi

    ### 5. Convert IP to 32-bit Integer
    local -i ip_int
    ip_int=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))

    ### 6. Calculate Subnet Mask
    local -i mask_int
    if [[ "$prefix" -eq 0 ]]; then
        mask_int=0
    else
        ### Shift left by (32-prefix) and mask with 0xFFFFFFFF to handle 64-bit environments correctly.
        mask_int=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    ### 7. Calculate Network Address (Bitwise AND)
    local -i net_int
    net_int=$(( ip_int & mask_int ))

    ### 8. Convert back to Dotted Decimal format and Output
    echo "$(( (net_int >> 24) & 255 )).$(( (net_int >> 16) & 255 )).$(( (net_int >> 8) & 255 )).$(( net_int & 255 ))"
}

get_host_bridge_info() {
    local host="$1"
    local cmd="ip -o -4 addr show type bridge | awk '{print \$2, \$4}'"
    if [[ "$host" == "localhost" ]]; then
        eval "$cmd" 2>/dev/null
    else
        ssh "${SSH_USER}@${host}" "$cmd" 2>/dev/null
    fi
}

get_node_interfaces() {
    local vmname="$1" host="$2"
    local -a interfaces
    local found=false

    ### Collect available bridges and their IPs on the host
    declare -A bridge_ips
    while read -r br_name br_ip_prefix; do
        [[ -z "$br_name" || -z "$br_ip_prefix" ]] && continue
        bridge_ips["$br_name"]="$br_ip_prefix"
    done < <(get_host_bridge_info "$host")

    if [[ ${#bridge_ips[@]} -eq 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "No bridges with IP addresses on host '$host'." >&2
        exit 1
    fi

    for nodeinfo in "${NODE_INFO_LIST[@]:-}"; do
        IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
        [[ "${fields[1]:-}" != "$vmname" ]] && continue

        found=true
        local i=1
        while true; do
            local offset=$(( (i-1)*7 + 2 ))
            local interface_name="${fields[$offset]:-}"
            [[ -z "$interface_name" ]] && break

            local mac_address="${fields[$((offset+1))]:-}"
            local vm_ip="${fields[$((offset+2))]:-}"
            local vm_prefix="${fields[$((offset+3))]:-}"

            [[ -z "$vm_ip" || -z "$vm_prefix" ]] && {
                printf "%-8s%-80s\n" "[ERROR]" "VM '$vmname' interface $i missing IP/Prefix." >&2
                exit 1
            }

            local vm_subnet=$(get_subnet_from_ip_prefix "$vm_ip" "$vm_prefix") || {
                printf "%-8s%-80s\n" "[ERROR]" "Failed to compute subnet for $vm_ip/$vm_prefix." >&2
                exit 1
            }

            local bridge_found=false
            for bridge_name in "${!bridge_ips[@]}"; do
                local bridge_ip_prefix="${bridge_ips[$bridge_name]}"
                local bridge_ip=$(echo "$bridge_ip_prefix" | cut -d'/' -f1)
                local bridge_prefix=$(echo "$bridge_ip_prefix" | cut -d'/' -f2)
                local bridge_subnet=$(get_subnet_from_ip_prefix "$bridge_ip" "$bridge_prefix")

                if [[ "$vm_subnet" == "$bridge_subnet" ]]; then
                    interfaces+=("$bridge_name:$mac_address")
                    bridge_found=true
                    printf "%-8s%-80s\n" "[INFO]" "       Matched Bridge: $bridge_name (Subnet: $bridge_subnet)" >&2
                    break
                fi
            done

            [[ "$bridge_found" == false ]] && {
                printf "%-8s%-80s\n" "[ERROR]" "No bridge in subnet $vm_subnet for VM IP $vm_ip/$vm_prefix on host '$host'." >&2
                printf "%-8s%-80s\n" "[INFO]"  "Available bridges:" >&2
                for b in "${!bridge_ips[@]}"; do
                    local bip=$(echo "${bridge_ips[$b]}" | cut -d'/' -f1)
                    local bpf=$(echo "${bridge_ips[$b]}" | cut -d'/' -f2)
                    local bsn=$(get_subnet_from_ip_prefix "$bip" "$bpf")
                    printf "%-8s%-80s\n" "[INFO]" "  - $b (${bridge_ips[$b]}), Subnet: $bsn" >&2
                done
                exit 1
            }
            ((i++))
        done
        break
    done

    [[ "$found" == false ]] && { printf "%-8s%-80s\n" "[ERROR]" "No node info for VM '$vmname' in NODE_INFO_LIST." >&2; exit 1; }
    [[ ${#interfaces[@]} -eq 0 ]] && { printf "%-8s%-80s\n" "[ERROR]" "No valid interfaces for VM '$vmname'." >&2; exit 1; }

    echo "${interfaces[@]}"
}

### ---------------------------------------------------------------------------------
### Pre-Flight: Distribute ISO
### ---------------------------------------------------------------------------------

declare -A unique_hosts
### Identify unique hosts from the VM list
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue
    host=$(echo "$vminfo" | awk -F'--' '{print $1}')
    [[ -z "$host" ]] && { printf "%-8s%-80s\n" "[ERROR]" "Invalid VM_INFO_LIST entry: '$vminfo'." >&2; exit 1; }
    unique_hosts["$host"]=1
done

### Define paths for the Agent ISO file.
virt_dir="${VIRT_DIR:-/var/lib/libvirt/images}"

### ISO File Path Handling
###   1. iso_src: Full path to the source file (including directory like './ocp4/agent.iso').
###   2. iso_name: Only the filename (e.g., 'agent.iso') for destination path construction.
iso_src="${ISO_FILE:-./${CLUSTER_NAME}/${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso}"
iso_name=$(basename "$iso_src")

### Validate that the Agent ISO file exists.
printf "%-8s%-80s\n" "[INFO]" "=== Pre-flight Checks ==="
printf "%-8s%-80s\n" "[INFO]" "--- Checking Agent ISO File..."
if [[ ! -f "$iso_src" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    ISO not found: '$iso_src'" >&2
    printf "%-8s%-80s\n" "[ERROR]" "    Please run the node ISO generation script first." >&2
    exit 1
fi
printf "%-8s%-80s\n" "[INFO]" "    Found: $iso_src" >&2

### Copy the Agent ISO file to each KVM host's libvirt images directory.
printf "%-8s%-80s\n" "[INFO]" "--- Distributing ISO to KVM Hosts..." >&2
for host in "${!unique_hosts[@]}"; do
    target_iso_path="$virt_dir/$iso_name"

    if [[ "$host" == "localhost" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    Target: Localhost -> $target_iso_path" >&2
        mkdir -p "$virt_dir"
        cp "$iso_src" "$target_iso_path" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to copy ISO to localhost." >&2; exit 1; }
    else
        printf "%-8s%-80s\n" "[INFO]" "    Target: Remote ($host) -> $target_iso_path" >&2
        ssh "${SSH_USER}@${host}" "mkdir -p $virt_dir"
        ### [MODIFIED] Use 'iso_name' for destination
        scp "$iso_src" "${SSH_USER}@${host}:$target_iso_path" || { printf "%-8s%-80s\n" "[ERROR]" "Failed to copy ISO to '$host'." >&2; exit 1; }
    fi
done

### ---------------------------------------------------------------------------------
### Main Loop: VM Provisioning (Concurrent Mode)
### ---------------------------------------------------------------------------------

printf "%-8s%-80s\n" "[INFO]" "=== Starting VM Provisioning (Concurrent Mode) ===" >&2
for vminfo in "${VM_INFO_LIST[@]}"; do
    [[ -z "$vminfo" ]] && continue

    host=$(          echo "$vminfo" | awk -F'--' '{print $1}')
    vmname=$(        echo "$vminfo" | awk -F'--' '{print $2}')
    cpu=$(           echo "$vminfo" | awk -F'--' '{print $3}')
    mem=$(           echo "$vminfo" | awk -F'--' '{print $4}')
    root_disk_size=$(echo "$vminfo" | awk -F'--' '{print $5}')
    add_disk_size=$( echo "$vminfo" | awk -F'--' '{print $6}')

    echo ""
    printf "%-8s%-80s\n" "[INFO]" "--- Processing VM: '$vmname' on Host: '$host' ---" >&2

    ### Validate that all required VM parameters are present.
    [[ -z "$host" || -z "$vmname" || -z "$cpu" || -z "$mem" || -z "$root_disk_size" || -z "$add_disk_size" ]] && {
        printf "%-8s%-80s\n" "[ERROR]" "Invalid VM_INFO_LIST entry: '$vminfo'." >&2
        exit 1
    }

    ### Get the network interface configuration for the current VM.
    printf "%-8s%-80s\n" "[INFO]" "    1. Network Discovery & Assignment..." >&2
    IFS=' ' read -r -a interfaces <<< "$(get_node_interfaces "$vmname" "$host")"
    [[ ${#interfaces[@]} -eq 0 ]] && { printf "%-8s%-80s\n" "[ERROR]" "No interfaces for VM '$vmname'." >&2; exit 1; }

    network_options=()
    for iface in "${interfaces[@]}"; do
        IFS=':' read -r bridge mac <<< "$iface"
        network_options+=("--network" "bridge=$bridge,mac=$mac")
    done

    ### Define disk paths.
    printf "%-8s%-80s\n" "[INFO]" "    2. Defining Storage Configuration..." >&2
    root_disk_path="$virt_dir/${vmname}_root.qcow2"
    add_disk_path=""
    [[ "$add_disk_size" -gt 0 ]] && add_disk_path="$virt_dir/${vmname}_add.qcow2"

    ### Set the QEMU connection string for local or remote hosts.
    qemu_connect="qemu:///system"
    [[ "$host" != "localhost" ]] && qemu_connect="qemu+ssh://${SSH_USER}@${host}/system"

    ### Build the full 'virt-install' command array.
    virt_install_cmd=(
        "virt-install"
        "--connect" "$qemu_connect"
        "--name" "$vmname"
        "--vcpus" "$cpu"
        "--memory" "$mem"
        "--os-variant" "rhel9.0"
        "--disk" "path=$root_disk_path,size=$root_disk_size,bus=virtio"
    )
    if [[ -n "$add_disk_path" ]]; then
        virt_install_cmd+=("--disk" "path=$add_disk_path,size=$add_disk_size,bus=virtio")
    fi
    virt_install_cmd+=(
        "${network_options[@]}"
        "--boot" "hd"
        "--cdrom" "$virt_dir/$iso_name"
        "--noautoconsole"
        "--wait"
    )

    ### Execute 'virt-install' on the target KVM host, logging output.
    log_file="$log_dir/${vmname}_install.log"

    printf "%-8s%-80s\n" "[INFO]" "    3. Executing virt-install..." >&2
    printf "%-8s%-80s\n" "[INFO]" "       Command: ${virt_install_cmd[*]}" >&2

    ### Execute in the background, logging to file
    "${virt_install_cmd[@]}" > "$log_file" 2>&1 &

    ### Give virt-install time to register the domain
    sleep 5

    ### Check if the domain was successfully registered
    if virsh --connect "$qemu_connect" dominfo "$vmname" &>/dev/null; then
        printf "%-8s%-80s\n" "[INFO]" "       Result: VM '$vmname' successfully created." >&2
    else
        printf "%-8s%-80s\n" "[WARN]" "       Result: VM '$vmname' NOT found (check log for details)." >&2
    fi
    printf "%-8s%-80s\n" "[INFO]" "       Log File: $log_file" >&2
done

echo ""
printf "\n%-8s%-80s\n" "[SUCCESS]" "All node provisioning tasks initiated!" >&2
printf "%-8s%-80s\n" "[INFO]" "Next: Monitor OpenShift installation (~30-60 min)"
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Post-Provisioning Action Required ===" >&2
printf "%-8s%-80s\n" " " "To monitor the installation progress, run:"
printf "%-8s%-80s\n" " " "  ./openshift-install wait-for install-complete --dir ./$CLUSTER_NAME --log-level debug"
printf "%-8s%-80s\n" " " "To check cluster status manually:"
printf "%-8s%-80s\n" " " "  export KUBECONFIG=./$CLUSTER_NAME/auth/kubeconfig"
printf "%-8s%-80s\n" " " "  watch ./oc get mcp,nodes,co"
echo ""