#!/bin/bash

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions."
    exit 1
fi

### Clean up existing directory and ISO
if [[ -d "./$CLUSTER_NAME" ]]; then
    echo "[WARN] The directory ./$CLUSTER_NAME already exists and will be deleted."
    rm -Rf "./$CLUSTER_NAME"
    echo "[INFO] Directory ./$CLUSTER_NAME deleted."
fi

if [[ -f ./${CLUSTER_NAME}_agent.x86_64.iso ]]; then
    echo "[WARN] The file ./${CLUSTER_NAME}_agent.x86_64.iso already exists and will be deleted."
    rm -f ./${CLUSTER_NAME}_agent.x86_64.iso
    echo "[INFO] File ./${CLUSTER_NAME}_agent.x86_64.iso deleted."
fi

### Create output directory
mkdir -p "./$CLUSTER_NAME/orig" || {
    echo "[ERROR] Failed to create directory ./$CLUSTER_NAME/orig"
    exit 1
}

validate_non_empty "ROOT_DEVICE_NAME" "$ROOT_DEVICE_NAME"
validate_ip_or_host_regex "$NTP_SERVER_01"
if [[ -n "$NTP_SERVER_02" ]]; then
    validate_ip_or_host_regex "$NTP_SERVER_02"
fi
validate_ip_or_host_regex "$DNS_SERVER_01"
if [[ -n "$DNS_SERVER_02" ]]; then
    validate_ip_or_host_regex "$DNS_SERVER_02"
fi

validate_ip_or_host_regex "$RENDEZVOUS_IP"

### Count master and worker nodes
worker_count=0
master_count=0
for node in "${NODE_INFO_LIST[@]}"; do
    role=$(echo "$node" | awk -F "--" '{print $1}')
    if [[ "$role" == "worker" ]]; then
        ((worker_count++))
    elif [[ "$role" == "master" ]]; then
        ((master_count++))
    else
        echo "[ERROR] Invalid role in node: $node (must be master or worker)."
        exit 1
    fi
done

if [[ $master_count -ne 1 && $master_count -ne 3 ]]; then
    echo "[ERROR] Master node count must be 1 (SNO) or 3 (HA), got: $master_count"
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
if [[ -n "$NTP_SERVER_02" ]]; then
    cat << EOF >> ./$CLUSTER_NAME/orig/agent-config.yaml
  - $NTP_SERVER_02
EOF
fi
cat << EOF >> ./$CLUSTER_NAME/orig/agent-config.yaml
rendezvousIP: $RENDEZVOUS_IP
hosts:
EOF

### Node information validation and YAML generation
max_interfaces=${NODE_INTERFACE_MAX_NUM:-3}

for nodeinfo in "${NODE_INFO_LIST[@]}"; do
    # Convert separators and split
    IFS='|' read -r -a fields <<< "$(echo "$nodeinfo" | sed 's/--/|/g')"
    role="${fields[0]}"
    hostname="${fields[1]}"
    context="$role--$hostname"

    # Validate role and hostname
    validate_role "role" "$role" "$context"

    # Validate interfaces
    for ((i=1; i<=max_interfaces; i++)); do
        offset=$(( (i-1)*7 + 2 ))
        interface_name="${fields[$offset]:-}"
        mac_address="${fields[$((offset+1))]:-}"
        ip_address="${fields[$((offset+2))]:-}"
        prefix_length="${fields[$((offset+3))]:-}"
        destination="${fields[$((offset+4))]:-}"
        next_hop_address="${fields[$((offset+5))]:-}"
        table_id="${fields[$((offset+6))]:-}"

        # Break if no more interfaces
        if [[ -z "$interface_name" ]]; then
            [[ $i -eq 1 ]] && {
                echo "[ERROR] At least one interface required in node: $nodeinfo"
                exit 1
            }
            break
        fi

        # Validate interface fields
        validate_mac      "mac_address_$i"      "$mac_address"      "$context"
        validate_ipv4     "ip_address_$i"       "$ip_address"       "$context"
        validate_prefix   "prefix_length_$i"    "$prefix_length"    "$context"
        validate_cidr     "destination_$i"      "$destination"      "$context"
        validate_ipv4     "next_hop_address_$i" "$next_hop_address" "$context"
        validate_table_id "table_id_$i"         "$table_id"         "$context"

        # Store interface data for YAML
        eval "interface_name_$i=\$interface_name"
        eval "mac_address_$i=\$mac_address"
        eval "ip_address_$i=\$ip_address"
        eval "prefix_length_$i=\$prefix_length"
        eval "destination_$i=\$destination"
        eval "next_hop_address_$i=\$next_hop_address"
        eval "table_id_$i=\$table_id"

        unset interface_name
        unset ip_address
        unset prefix_length
        unset destination
        unset next_hope_address
        unset table_id
    done

    ### Generate YAML for node
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
  - hostname: ${hostname}.${CLUSTER_NAME}.${BASE_DOMAIN}
    role: $role
    rootDeviceHints:
      deviceName: $ROOT_DEVICE_NAME
    interfaces:
EOF
    for ((i=1; i<=max_interfaces; i++)); do
        if [[ -n "$(eval echo \$interface_name_$i)" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
      - name: $(eval echo \$interface_name_$i)
        macAddress: $(eval echo \$mac_address_$i)
EOF
        fi
    done

    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
    networkConfig:
      interfaces:
EOF
    for ((i=1; i<=max_interfaces; i++)); do
        if [[ -n "$(eval echo \$interface_name_$i)" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
        - name: $(eval echo \$interface_name_$i)
          type: ethernet
          state: up
          mac-address: $(eval echo \$mac_address_$i)
          ipv4:
            enabled: true
            address:
              - ip: $(eval echo \$ip_address_$i)
                prefix-length: $(eval echo \$prefix_length_$i)
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
    if [[ -n "$DNS_SERVER_02" ]]; then
        cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
            - $DNS_SERVER_02
EOF
    fi
    cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
          search:
            - ${CLUSTER_NAME}.${BASE_DOMAIN}
      routes:
        config:
EOF
    for ((i=1; i<=max_interfaces; i++)); do
        if [[ -n "$(eval echo \$interface_name_$i)" ]]; then
            cat << EOF >> "./$CLUSTER_NAME/orig/agent-config.yaml"
          - destination: $(eval echo \$destination_$i)
            next-hop-address: $(eval echo \$next_hop_address_$i)
            next-hop-interface: $(eval echo \$interface_name_$i)
            table-id: $(eval echo \$table_id_$i)
EOF
        fi
    done
done

### Check if validation and YAML generation passed
if [[ $? -eq 0 ]]; then
    echo "INFO: Node info validated and agent-config.yaml generated successfully"
else
    echo "[ERROR] Validation or YAML generation failed"
    exit 1
fi

### List directory structure
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "$CLUSTER_NAME"
fi