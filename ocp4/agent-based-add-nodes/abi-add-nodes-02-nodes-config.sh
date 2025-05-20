#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions." >&2
    exit 1
fi

### Clean up existing directory and ISO
if [[ -f ./${CLUSTER_NAME}_nodes.x86_64.iso ]]; then
    echo "[WARN] The file ./${CLUSTER_NAME}_nodes.x86_64.iso already exists and will be deleted."
    rm -f ./${CLUSTER_NAME}_nodes.x86_64.iso
    echo "[INFO] File ./${CLUSTER_NAME}_nodes.x86_64.iso deleted."
fi

### Create output directory
if [[ ! -d "./$CLUSTER_NAME/add-nodes" ]]; then
    mkdir -p "./$CLUSTER_NAME/add-nodes" || {
        echo "[ERROR] Failed to create directory ./$CLUSTER_NAME/add-nodes" >&2
        exit 1
    }
    echo "[INFO] Created directory ./$CLUSTER_NAME/add-nodes"
fi

### Validate critical variables
validate_non_empty "CLUSTER_NAME"     "$CLUSTER_NAME"
validate_non_empty "ROOT_DEVICE_NAME" "$ROOT_DEVICE_NAME"
validate_ip_or_host_regex "$DNS_SERVER_01"
if [[ -n "${DNS_SERVER_02:-}" ]]; then
    validate_ip_or_host_regex "$DNS_SERVER_02"
fi
validate_domain "BASE_DOMAIN" "$BASE_DOMAIN" "cluster configuration"

### Create nodes-config.yaml
cat << EOF > ./$CLUSTER_NAME/add-nodes/nodes-config.yaml
hosts:
EOF

### Node information validation and YAML generation
for nodeinfo in "${NODE_INFO_LIST[@]}"; do
    if [[ -z "$nodeinfo" ]]; then
        echo "[ERROR] Empty node info entry in NODE_INFO_LIST. Skipping..." >&2
        continue
    fi

    ### Convert separators and split
    sed_output="$(echo "$nodeinfo" | sed 's/--/|/g')"
    IFS='|' read -r -a fields <<< "$sed_output"
    role="${fields[0]}"
    hostname="${fields[1]}"
    context="$role--$hostname"

    ### Validate role and hostname
    validate_role      "role"     "$role"     "$context"
    validate_non_empty "hostname" "$hostname" "$context"

    ### Calculate number of interfaces dynamically
    interface_count=$(( (${#fields[@]} - 2) / 7 ))
    if [[ $interface_count -lt 1 ]]; then
        echo "[ERROR] At least one interface required for node: $context" >&2
        exit 1
    fi
    if [[ $(( (${#fields[@]} - 2) % 7 )) -ne 0 ]]; then
        echo "[ERROR] Invalid number of fields for interfaces in node: $context. Expected multiple of 7 fields per interface, got ${#fields[@]} fields." >&2
        exit 1
    fi

    echo "[INFO] Processing node: $context with $interface_count interface(s)"

    ### Initialize arrays for interface data
    declare -A interfaces

    ### Validate interfaces
    for ((i=1; i<=interface_count; i++)); do
        offset=$(( (i-1)*7 + 2 ))
        interface_name="${fields[$offset]:-}"
        mac_address="${fields[$((offset+1))]:-}"
        ip_address="${fields[$((offset+2))]:-}"
        prefix_length="${fields[$((offset+3))]:-}"
        destination="${fields[$((offset+4))]:-}"
        next_hop_address="${fields[$((offset+5))]:-}"
        table_id="${fields[$((offset+6))]:-}"

        ### Validate interface fields
        validate_non_empty "interface_name_$i" "$interface_name" "$context"
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
    done

    ### Generate YAML for node
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

    ### Clean up interfaces array for the next host
    unset interfaces
done

### Check if validation and YAML generation passed
if [[ $? -eq 0 ]]; then
    echo "[INFO] Node info validated and nodes-config.yaml generated successfully"
else
    echo "[ERROR] Validation or YAML generation failed" >&2
    exit 1
fi

### List directory structure
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME" || echo "[WARNING] tree command failed" >&2
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "$CLUSTER_NAME" || echo "[WARNING] ls command failed" >&2
fi