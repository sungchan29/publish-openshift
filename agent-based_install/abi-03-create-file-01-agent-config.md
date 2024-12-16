
```bash

vi abi-03-create-file-01-agent-config.sh

```

```bash
#!/bin/bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..."
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "Error: BASE_DOMAIN variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${NTP_SERVER_01}" ]]; then
    echo "Error: NTP_SERVER_01 variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${DNS_SERVER_01}" ]]; then
    echo "Error: DNS_SERVER_01 variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${NODE_INFO_LIST}" ]]; then
    echo "Error: NODE_INFO_LIST variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${ROOT_DEVICE_NAME}" ]]; then
    echo "Error: ROOT_DEVICE_NAME variable is empty. Exiting..."
    exit 1
fi

#####################
#####################
#####################

worker_count=0
for node in $NODE_INFO_LIST; do
  if [[ $node == *"--worker--"* ]]; then
    ((worker_count++))
  fi
done
if [[ $worker_count -gt 0 ]]; then
    if [[ -z $RENDEZVOUS_IP ]]; then
        echo "Error: RENDEZVOUS_IP variable is empty. Exiting..."
        exit 1
    fi
fi


if [[ -d ./$CLUSTER_NAME ]]; then
    rm -Rf ./$CLUSTER_NAME
fi
if [[ -f ./${CLUSTER_NAME}_agent.x86_64.iso ]]; then
    rm -f ./${CLUSTER_NAME}_agent.x86_64.iso
fi

mkdir -p ./${CLUSTER_NAME}/orig

cat << EOF  > ./${CLUSTER_NAME}/orig/agent-config.yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
EOF

### Config for NTP
if [[ -n $NTP_SERVER_01 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
additionalNTPSources:
  - $NTP_SERVER_01
EOF

    if [[ -n $NTP_SERVER_02 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
  - $NTP_SERVER_02
EOF

    fi
fi

### Config for rendezvousIP
if [[ $worker_count -gt 0 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
rendezvousIP: ${RENDEZVOUS_IP}
EOF

fi

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
hosts:
EOF

for nodeinfo in ${NODE_INFO_LIST}; do
    role=$(               echo ${nodeinfo} |awk -F "--" '{print  $1}' )
    hostname=$(           echo ${nodeinfo} |awk -F "--" '{print  $2}' )
    interface_name_1=$(   echo ${nodeinfo} |awk -F "--" '{print  $3}' )
    mac_address_1=$(      echo ${nodeinfo} |awk -F "--" '{print  $4}' )
    ip_address_1=$(       echo ${nodeinfo} |awk -F "--" '{print  $5}' )
    prefix_length_1=$(    echo ${nodeinfo} |awk -F "--" '{print  $6}' )
    destination_1=$(      echo ${nodeinfo} |awk -F "--" '{print  $7}' )
    next_hop_address_1=$( echo ${nodeinfo} |awk -F "--" '{print  $8}' )
    table_id_1=$(         echo ${nodeinfo} |awk -F "--" '{print  $9}' )
    interface_name_2=$(   echo ${nodeinfo} |awk -F "--" '{print $10}' )
    mac_address_2=$(      echo ${nodeinfo} |awk -F "--" '{print $11}' )
    ip_address_2=$(       echo ${nodeinfo} |awk -F "--" '{print $12}' )
    prefix_length_2=$(    echo ${nodeinfo} |awk -F "--" '{print $13}' )
    destination_2=$(      echo ${nodeinfo} |awk -F "--" '{print $14}' )
    next_hop_address_2=$( echo ${nodeinfo} |awk -F "--" '{print $15}' )
    table_id_2=$(         echo ${nodeinfo} |awk -F "--" '{print $16}' )
    interface_name_3=$(   echo ${nodeinfo} |awk -F "--" '{print $17}' )
    mac_address_3=$(      echo ${nodeinfo} |awk -F "--" '{print $18}' )
    ip_address_3=$(       echo ${nodeinfo} |awk -F "--" '{print $19}' )
    prefix_length_3=$(    echo ${nodeinfo} |awk -F "--" '{print $20}' )
    destination_3=$(      echo ${nodeinfo} |awk -F "--" '{print $21}' )
    next_hop_address_3=$( echo ${nodeinfo} |awk -F "--" '{print $22}' )
    table_id_3=$(         echo ${nodeinfo} |awk -F "--" '{print $23}' )

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
  - hostname: ${hostname}.${CLUSTER_NAME}.${BASE_DOMAIN}
    role: ${role}
    interfaces:
      - name: ${interface_name_1}
        macAddress: ${mac_address_1}
    rootDeviceHints:
      deviceName: ${ROOT_DEVICE_NAME}
    networkConfig:
      interfaces:
        - name: ${interface_name_1}
          type: ethernet
          state: up
          mac-address: ${mac_address_1}
          ipv4:
            enabled: true
            address:
              - ip: ${ip_address_1}
                prefix-length: ${prefix_length_1}
            dhcp: false
          ipv6:
            enabled: false
EOF

    if [[ -n $interface_name_2 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
        - name: ${interface_name_2}
          type: ethernet
          state: up
          mac-address: ${mac_address_2}
          ipv4:
            enabled: true
            address:
              - ip: ${ip_address_2}
                prefix-length: ${prefix_length_2}
            dhcp: false
          ipv6:
            enabled: false
EOF

    fi
    if [[ -n $interface_name_3 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
        - name: ${interface_name_3}
          type: ethernet
          state: up
          mac-address: ${mac_address_3}
          ipv4:
            enabled: true
            address:
              - ip: ${ip_address_3}
                prefix-length: ${prefix_length_3}
            dhcp: false
          ipv6:
            enabled: false
EOF

    fi

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER_01}
EOF

    if [[ -n $DNS_SERVER_02 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
            - ${DNS_SERVER_02}
EOF

    fi

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
          search:
            - ${CLUSTER_NAME}.${BASE_DOMAIN}
      routes:
        config:
          - destination: $destination_1
            next-hop-address: $next_hop_address_1
            next-hop-interface: ${interface_name_1}
            table-id: ${table_id_1}
EOF

    if [[ -n $interface_name_2 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
          - destination: $destination_2
            next-hop-address: $next_hop_address_2
            next-hop-interface: ${interface_name_2}
            table-id: ${table_id_2}
EOF

    fi
    if [[ -n $interface_name_3 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/agent-config.yaml
          - destination: $destination_3
            next-hop-address: $next_hop_address_3
            next-hop-interface: ${interface_name_3}
            table-id: ${table_id_3}
EOF

    fi
done
```

```bash

sh abi-03-create-file-01-agent-config.sh

```