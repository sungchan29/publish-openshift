#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Agent-Based Installation ISO
### ---------------------------------------------------------------------------------
### This script prepares the Agent-Based Installation (ABI) configuration and
### generates the bootable ISO file for a disconnected OpenShift cluster.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load and Validate Configuration
### ---------------------------------------------------------------------------------
### Source the configuration file to access all required variables.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"

### Check if the configuration file exists and source it.
if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' could not be found. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Validate critical variables to ensure the script can proceed.
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "ROOT_DEVICE_NAME" "$ROOT_DEVICE_NAME"

### ---------------------------------------------------------------------------------
### Cleanup Existing Files and Directories
### ---------------------------------------------------------------------------------
### Clean up any existing directory and ISO file from previous runs.
echo "--- Starting cleanup of old installation files..."
if [[ -d "./$CLUSTER_NAME" ]]; then
    echo "WARNING: The directory './$CLUSTER_NAME' already exists. Deleting it now..."
    rm -Rf "./$CLUSTER_NAME"
    echo "INFO: Directory './$CLUSTER_NAME' has been removed."
fi

if [[ -f ./${CLUSTER_NAME}_agent.x86_64.iso ]]; then
    echo "WARNING: The ISO file './${CLUSTER_NAME}_agent.x86_64.iso' already exists. Deleting it now..."
    rm -f ./${CLUSTER_NAME}_agent.x86_64.iso
    echo "INFO: The ISO file has been removed."
fi

### ---------------------------------------------------------------------------------
### Prepare Output Directory
### ---------------------------------------------------------------------------------
### Create the output directory to store all generated configuration files.
echo "--- Preparing output directory..."
mkdir -p "./$CLUSTER_NAME/orig" || {
    echo "ERROR: Failed to create directory './$CLUSTER_NAME/orig'. Exiting." >&2
    exit 1
}
echo "INFO: Created directory './$CLUSTER_NAME/orig'."

### ---------------------------------------------------------------------------------
### Validate Node Counts
### ---------------------------------------------------------------------------------
### Count the number of master and worker nodes from the configuration list.
echo "--- Validating node information from the configuration file..."
unset master_count worker_count
master_count=0
worker_count=0
for node in "${NODE_INFO_LIST[@]}"; do
    if [[ -z "$node" ]]; then
        echo "ERROR: Empty node entry found in NODE_INFO_LIST. Please check your configuration." >&2
        exit 1
    fi
    if [[ ! "$node" =~ ^(master|worker)-- ]]; then
        echo "ERROR: Invalid node format: '$node'. Entry must start with 'master--' or 'worker--'." >&2
        exit 1
    fi
    role="${node%%--*}"
    if [[ "$role" == "worker" ]]; then
        worker_count=$((worker_count + 1))
    elif [[ "$role" == "master" ]]; then
        master_count=$((master_count + 1))
    else
        echo "ERROR: Invalid role in node: '$node'. Role must be 'master' or 'worker'." >&2
        exit 1
    fi
done

### Ensure the master node count is either 1 (SNO) or 3 (HA).
if [[ $master_count -ne 1 && $master_count -ne 3 ]]; then
    echo "ERROR: Invalid master node count. Must be 1 (for SNO) or 3 (for HA), but got: $master_count." >&2
    exit 1
fi
echo "INFO: Node counts validated successfully (Masters: $master_count, Workers: $worker_count)."

### ---------------------------------------------------------------------------------
### Generate 'agent-config.yaml'
### ---------------------------------------------------------------------------------
### This is the core configuration file for the agent-based installation.
echo "--- Generating 'agent-config.yaml' with network and host information..."

### Start the YAML file with base configuration.
cat << EOF > "./$CLUSTER_NAME/orig/agent-config.yaml"
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: $CLUSTER_NAME
additionalNTPSources:
  - $NTP_SERVER_01
EOF
if [[ -n "${NTP_SERVER_02:-}" ]]; then
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
  - $NTP_SERVER_02
EOF
fi
if [[ -n "${RENDEZVOUS_IP:-}" ]]; then
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
rendezvousIP: $RENDEZVOUS_IP
EOF
fi
cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
hosts:
EOF

### Iterate through the node list to append each host's configuration.
for nodeinfo in "${NODE_INFO_LIST[@]}"; do
    ### Convert separators and split the string into an array.
    sed_output="$(echo "$nodeinfo" | sed 's/--/|/g')"
    IFS='|' read -r -a fields <<< "$sed_output"
    role="${fields[0]}"
    hostname="${fields[1]}"
    
    ### Initialize an array to hold interface data for the current node.
    declare -A interfaces
    interface_count=0

    ### Validate and parse interface details from the input string.
    i=1
    while true; do
        offset=$(( (i-1)*7 + 2 ))
        interface_name="${fields[$offset]:-}"
        mac_address="${fields[$((offset+1))]:-}"
        ip_address="${fields[$((offset+2))]:-}"
        prefix_length="${fields[$((offset+3))]:-}"
        destination="${fields[$((offset+4))]:-}"
        next_hop_address="${fields[$((offset+5))]:-}"
        table_id="${fields[$((offset+6))]:-}"

        ### Break the loop if no more interfaces are found.
        if [[ -z "$interface_name" ]]; then
            if [[ $i -eq 1 ]]; then
                echo "ERROR: At least one interface is required in node: $nodeinfo." >&2
                exit 1
            fi
            break
        fi

        ### Store interface data in the associative array.
        interfaces["name_$i"]="$interface_name"
        interfaces["mac_$i"]="$mac_address"
        interfaces["ip_$i"]="$ip_address"
        interfaces["prefix_$i"]="$prefix_length"
        interfaces["dest_$i"]="$destination"
        interfaces["next_hop_$i"]="$next_hop_address"
        interfaces["table_$i"]="$table_id"

        interface_count=$((interface_count + 1))
        i=$((i + 1))
    done

    ### Generate the YAML block for the current host's configuration.
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
  - hostname: ${hostname}.${CLUSTER_NAME}.${BASE_DOMAIN}
    role: $role
    rootDeviceHints:
      deviceName: $ROOT_DEVICE_NAME
    interfaces:
EOF
    for ((j=1; j<=interface_count; j++)); do
        if [[ -n "${interfaces[name_$j]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
      - name: ${interfaces[name_$j]}
        macAddress: ${interfaces[mac_$j]}
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
    networkConfig:
      interfaces:
EOF
    for ((j=1; j<=interface_count; j++)); do
        if [[ -n "${interfaces[name_$j]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
        - name: ${interfaces[name_$j]}
          type: ethernet
          state: up
          mac-address: ${interfaces[mac_$j]}
          ipv4:
            enabled: true
            address:
              - ip: ${interfaces[ip_$j]}
                prefix-length: ${interfaces[prefix_$j]}
            dhcp: false
          ipv6:
            enabled: false
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
      dns-resolver:
        config:
          server:
            - $DNS_SERVER_01
EOF
    if [[ -n "${DNS_SERVER_02:-}" ]]; then
        cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
            - $DNS_SERVER_02
EOF
    fi
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
          search:
            - ${CLUSTER_NAME}.${BASE_DOMAIN:-default.domain}
      routes:
        config:
EOF
    for ((j=1; j<=interface_count; j++)); do
        if [[ -n "${interfaces[name_$j]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
          - destination: ${interfaces[dest_$j]}
            next-hop-address: ${interfaces[next_hop_$j]}
            next-hop-interface: ${interfaces[name_$j]}
            table-id: ${interfaces[table_$j]}
EOF
        fi
    done

    ### Clean up interfaces array for the next host.
    unset interfaces
done
echo "INFO: 'agent-config.yaml' has been successfully generated."

### ---------------------------------------------------------------------------------
### Display Output Directory Contents
### ---------------------------------------------------------------------------------
### Provide a summary of the generated files to the user.
echo "--- Listing the contents of the newly created configuration directory '$CLUSTER_NAME'..."
if command -v tree >/dev/null 2>&1; then
    tree "$CLUSTER_NAME"
else
    ls -lR "$CLUSTER_NAME"
fi