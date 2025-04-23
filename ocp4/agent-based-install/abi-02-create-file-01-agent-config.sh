#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Clean up existing directory and ISO
if [[ -d "./$CLUSTER_NAME" ]]; then
    echo "[WARN] The directory ./$CLUSTER_NAME already exists and will be deleted." || echo "[WARNING] tee failed for directory deletion warning" >&2
    rm -Rf "./$CLUSTER_NAME"
    echo "[INFO] Directory ./$CLUSTER_NAME deleted." || echo "[WARNING] tee failed for directory deletion info" >&2
fi

if [[ -f ./${CLUSTER_NAME}_agent.x86_64.iso ]]; then
    echo "[WARN] The file ./${CLUSTER_NAME}_agent.x86_64.iso already exists and will be deleted." || echo "[WARNING] tee failed for ISO deletion warning" >&2
    rm -f ./${CLUSTER_NAME}_agent.x86_64.iso
    echo "[INFO] File ./${CLUSTER_NAME}_agent.x86_64.iso deleted." || echo "[WARNING] tee failed for ISO deletion info" >&2
fi

### Create output directory
mkdir -p "./$CLUSTER_NAME/orig" || {
    echo "[ERROR] Failed to create directory ./$CLUSTER_NAME/orig" >&2
    exit 1
}
echo "[INFO] Created directory ./$CLUSTER_NAME/orig" || echo "[WARNING] tee failed for directory creation" >&2

### Validate critical variables
validate_non_empty "CLUSTER_NAME"     "$CLUSTER_NAME"
validate_non_empty "ROOT_DEVICE_NAME" "$ROOT_DEVICE_NAME"
validate_ip_or_host_regex "$NTP_SERVER_01"
validate_ip_or_host_regex "$RENDEZVOUS_IP"
validate_ip_or_host_regex "$DNS_SERVER_01"
if [[ -n "${NTP_SERVER_02:-}" ]]; then
    validate_ip_or_host_regex "$NTP_SERVER_02"
fi
if [[ -n "${DNS_SERVER_02:-}" ]]; then
    validate_ip_or_host_regex "$DNS_SERVER_02"
fi

### Count master and worker nodes
unset master_count worker_count  # Ensure no prior interference
master_count=0
worker_count=0
for node in "${NODE_INFO_LIST[@]}"; do
    if [[ -z "$node" ]]; then
        echo "[ERROR] Empty node entry in NODE_INFO_LIST" >&2
        exit 1
    fi
    if [[ ! "$node" =~ ^(master|worker)-- ]]; then
        echo "[ERROR] Invalid node format: '$node' (must start with master-- or worker--)" >&2
        exit 1
    fi
    role="${node%%--*}"
    if [[ "$role" == "worker" ]]; then
        worker_count=$((worker_count + 1))
    elif [[ "$role" == "master" ]]; then
        master_count=$((master_count + 1))
    else
        echo "[ERROR] Invalid role in node: '$node' (must be master or worker)." >&2
        exit 1
    fi
done

if [[ $master_count -ne 1 && $master_count -ne 3 ]]; then
    echo "[ERROR] Master node count must be 1 (SNO) or 3 (HA), got: $master_count" >&2
    exit 1
fi

### Create agent-config.yaml
cat << EOF > ./$CLUSTER_NAME/orig/agent-config.yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: $CLUSTER_NAME
additionalNTPSources:
  - $NTP_SERVER_01
EOF
if [[ -n "${NTP_SERVER_02:-}" ]]; then
    cat << EOF >> ./$CLUSTER_NAME/orig/agent-config.yaml
  - $NTP_SERVER_02
EOF
fi
cat << EOF >> ./$CLUSTER_NAME/orig/agent-config.yaml
rendezvousIP: $RENDEZVOUS_IP
hosts:
EOF

### Node information validation and YAML generation
max_interfaces=${NODE_INTERFACE_MAX_NUM}

for nodeinfo in "${NODE_INFO_LIST[@]}"; do
    ### Convert separators and split
    sed_output="$(echo "$nodeinfo" | sed 's/--/|/g')"
    IFS='|' read -r -a fields <<< "$sed_output"
    role="${fields[0]}"
    hostname="${fields[1]}"
    context="$role--$hostname"

    ### Validate role and hostname
    validate_role "role" "$role" "$context"

    ### Initialize arrays for interface data
    declare -A interfaces
    interface_count=0

    ### Validate interfaces
    for ((i=1; i<=max_interfaces; i++)); do
        offset=$(( (i-1)*7 + 2 ))
        interface_name="${fields[$offset]:-}"
        mac_address="${fields[$((offset+1))]:-}"
        ip_address="${fields[$((offset+2))]:-}"
        prefix_length="${fields[$((offset+3))]:-}"
        destination="${fields[$((offset+4))]:-}"
        next_hop_address="${fields[$((offset+5))]:-}"
        table_id="${fields[$((offset+6))]:-}"

        ### Break if no more interfaces
        if [[ -z "$interface_name" ]]; then
            [[ $i -eq 1 ]] && {
                echo "[ERROR] At least one interface required in node: $nodeinfo" >&2
                exit 1
            }
            break
        fi

        ### Validate interface fields
        validate_mac      "mac_address_$i"      "$mac_address"      "$context"
        validate_ipv4     "ip_address_$i"       "$ip_address"       "$context"
        validate_prefix   "prefix_length_$i"    "$prefix_length"    "$context"
        validate_cidr     "destination_$i"      "$destination"      "$context"
        validate_ipv4     "next_hop_address_$i" "$next_hop_address" "$context"
        validate_table_id "table_id_$i"         "$table_id"         "$context"

        ### Store interface data in array
        interfaces["name_$i"]="$interface_name"
        interfaces["mac_$i"]="$mac_address"
        interfaces["ip_$i"]="$ip_address"
        interfaces["prefix_$i"]="$prefix_length"
        interfaces["dest_$i"]="$destination"
        interfaces["next_hop_$i"]="$next_hop_address"
        interfaces["table_$i"]="$table_id"

        ### Increment interface_count safely
        interface_count=$((interface_count + 1)) || {
            echo "[ERROR] Failed to increment interface_count. Current value: '$interface_count'" >&2
            exit 1
        }
    done

    ### Generate YAML for node
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
  - hostname: ${hostname}.${CLUSTER_NAME}.${BASE_DOMAIN:-default.domain}
    role: $role
    rootDeviceHints:
      deviceName: $ROOT_DEVICE_NAME
    interfaces:
EOF
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
      - name: ${interfaces[name_$i]}
        macAddress: ${interfaces[mac_$i]}
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
    networkConfig:
      interfaces:
EOF
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
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
    for ((i=1; i<=interface_count; i++)); do
        if [[ -n "${interfaces[name_$i]}" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
          - destination: ${interfaces[dest_$i]}
            next-hop-address: ${interfaces[next_hop_$i]}
            next-hop-interface: ${interfaces[name_$i]}
            table-id: ${interfaces[table_$i]}
EOF
        fi
    done

    ### Clean up interfaces array for the next host
    unset interfaces
done

### Check if validation and YAML generation passed
if [[ $? -eq 0 ]]; then
    echo "[INFO] Node info validated and agent-config.yaml generated successfully" || echo "[WARNING] tee failed for success message" >&2
else
    echo "[ERROR] Validation or YAML generation failed" >&2
    exit 1
fi

### List directory structure
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$CLUSTER_NAME':" || echo "[WARNING] tee failed for directory structure" >&2
    tree "$CLUSTER_NAME" || echo "[WARNING] tee failed for tree output" >&2
else
    echo "[INFO] 'tree' command not found, listing files with ls:" || echo "[WARNING] tee failed for ls message" >&2
    ls -lR "$CLUSTER_NAME" || echo "[WARNING] tee failed for ls output" >&2
fi