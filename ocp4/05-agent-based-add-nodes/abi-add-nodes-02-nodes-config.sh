#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Add-Nodes Configuration
### ---------------------------------------------------------------------------------
### This script generates the 'nodes-config.yaml' file required to create a bootable ISO for adding new nodes to an existing OpenShift cluster.

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

### ---------------------------------------------------------------------------------
### Validate Environment and Setup
### ---------------------------------------------------------------------------------
### Validate that critical environment variables from the config are set.
printf "%-8s%-80s\n"     "[INFO]" "=== Validating prerequisites ==="
validate_non_empty "CLUSTER_NAME"     "$CLUSTER_NAME"
validate_non_empty "ROOT_DEVICE_NAME" "$ROOT_DEVICE_NAME"

if [[ ! -v NODE_INFO_LIST ]] || [[ "${#NODE_INFO_LIST[@]}" -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The array 'NODE_INFO_LIST' is empty."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Prepare Environment
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting cleanup of previous installation files. ==="
### Clean up any existing ISO file from a previous run.
if [[ -f ./${CLUSTER_NAME}_nodes.x86_64.iso ]]; then
    printf "%-8s%-80s\n" "[WARN]" "    > Existing nodes ISO file found. Removing it..."
    rm -f ./${CLUSTER_NAME}_nodes.x86_64.iso
fi
### Create the output directory for the generated configuration.
if [[ -d "./$CLUSTER_NAME/add-nodes" ]]; then
    printf "%-8s%-80s\n" "[WARN]" "    > Existing directory './$CLUSTER_NAME/add-nodes' found. Removing it..."
    rm -Rf "./$CLUSTER_NAME/add-nodes"
fi
printf "%-8s%-80s\n" "[INFO]" "    > Creating output directory './$CLUSTER_NAME/add-nodes'..."
mkdir -p "./$CLUSTER_NAME/add-nodes" || {
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to create directory './$CLUSTER_NAME/add-nodes'. Exiting..."
    exit 1
}

### ---------------------------------------------------------------------------------
### Generate 'node-config.yaml'
### ---------------------------------------------------------------------------------
### This is the core configuration file for the agent-based installation.
printf "%-8s%-80s\n" "[INFO]" "=== Generating 'nodes-config.yaml' ==="

### Initialize the YAML file with the top-level 'hosts' key.
printf "%-8s%-80s\n" "[INFO]" "    > Initialize the YAML file with the top-level 'hosts' key."
cat << EOF > "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
hosts:
EOF

printf "%-8s%-80s\n" "[INFO]" "    > Iterate through the node list to append each host's specific configuration. ..."
### Iterate through the node list to append each host's specific configuration.
for nodeinfo in "${NODE_INFO_LIST[@]}"; do
    if [[ -z "$nodeinfo" ]]; then
        printf "%-8s%-80s\n" "[WARN]" "      Empty entry found in NODE_INFO_LIST. Skipping."
        continue
    fi

    ### Parse the node info string into an array for easier access.
    sed_output="$(echo "$nodeinfo" | sed 's/--/|/g')"
    IFS='|' read -r -a fields <<< "$sed_output"
    role="${fields[0]}"
    hostname="${fields[1]}"
    context="$role--$hostname"

    validate_non_empty "hostname" "$hostname" "$context"

    printf "%-8s%-80s\n" "[INFO]" "      -- node name: $hostname"
    ### Dynamically calculate the number of interfaces based on the field count.
    interface_count=$(( (${#fields[@]} - 2) / 7 ))
    if [[ $interface_count -lt 1 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       At least one interface is required for node '$context'. Exiting..."
        exit 1
    fi
    if [[ $(( (${#fields[@]} - 2) % 7 )) -ne 0 ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       Invalid number of interface fields for node '$context'. Exiting..."
        exit 1
    fi

    printf "%-8s%-80s\n" "[INFO]" "    > Processing node '$context' with $interface_count interface(s)..."

    ### Initialize an associative array to hold interface data for the current node.
    declare -A interfaces=()
    ### Parse all interface details from the input string.
    for ((i=1; i<=interface_count; i++)); do
        offset=$(( (i-1)*7 + 2 ))
        interfaces["name_$i"]="${fields[$offset]:-}"
        interfaces["mac_$i"]="${fields[$((offset+1))]:-}"
        interfaces["ip_$i"]="${fields[$((offset+2))]:-}"
        interfaces["prefix_$i"]="${fields[$((offset+3))]:-}"
        interfaces["dest_$i"]="${fields[$((offset+4))]:-}"
        interfaces["next_hop_$i"]="${fields[$((offset+5))]:-}"
        interfaces["table_$i"]="${fields[$((offset+6))]:-}"
    done

    ### Generate the YAML block for the current host and append it to the file.
    cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
  - hostname: ${hostname}.${CLUSTER_NAME}.${BASE_DOMAIN}
    role: $role
    rootDeviceHints:
      deviceName: $ROOT_DEVICE_NAME
    interfaces:
EOF
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
      - name: ${interfaces[name_$i]}
        macAddress: ${interfaces[mac_$i]}
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
    networkConfig:
      interfaces:
EOF
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
        - name: ${interfaces[name_$i]}
          type: ethernet
          state: up
          mac-address: ${interfaces[mac_$i]}
          ipv4:
            enabled: true
            address:
              - ip: ${interfaces[ip_$i]}
                prefix-length: ${interfaces[prefix_$i]}
            dhcp: false
          ipv6:
            enabled: false
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
      dns-resolver:
        config:
          server:
            - $DNS_SERVER_01
EOF
    if [[ -n "${DNS_SERVER_02:-}" ]]; then
        cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
            - $DNS_SERVER_02
EOF
    fi
    cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
          search:
            - ${CLUSTER_NAME}.${BASE_DOMAIN}
      routes:
        config:
EOF
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/add-nodes/nodes-config.yaml"
          - destination: ${interfaces[dest_$i]}
            next-hop-address: ${interfaces[next_hop_$i]}
            next-hop-interface: ${interfaces[name_$i]}
            table-id: ${interfaces[table_$i]}
EOF
        fi
    done
done
printf "%-8s%-80s\n" "[INFO]" "    > 'nodes-config.yaml' generation is complete."

### ---------------------------------------------------------------------------------
### Display Output Directory Contents
### ---------------------------------------------------------------------------------
### Provide a summary of the generated files to the user.
printf "%-8s%-80s\n" "[INFO]" "=== Generated Configuration Files ==="
if command -v tree >/dev/null 2>&1; then
    tree "$CLUSTER_NAME" || printf "%-8s%-80s\n" "[WARN]" "    'tree' command failed to execute."
else
    printf "%-8s%-80s\n" "[INFO]" "    'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "$CLUSTER_NAME" || printf "%-8s%-80s\n" "[WARN]" "    'ls' command failed to execute."
fi
echo ""