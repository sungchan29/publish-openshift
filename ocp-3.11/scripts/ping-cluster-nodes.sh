#!/bin/bash

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"
TIMEOUT_SECONDS=300 # 5 minutes
PING_INTERVAL_SECONDS=2


# --- Check if an argument is provided ---
if [ -z "$1" ]; then
    echo "[ERROR] Usage: $0 <ansible_host_pattern>"
    echo "  Example: $0 masters"
    echo "  Example: $0 nodes"
    echo "  Example: $0 new_nodes"
    exit 1
fi
# -----------------------------------------

HOST_PATTERN="$1"
mapfile -t hosts < <(ansible -i $INVENTORY_FILE $HOST_PATTERN --list-hosts |grep -v " hosts " | awk '{$1=$1};1')
if [ ${#hosts[@]} -eq 0 ]; then
    echo "[ERROR] No hosts found for cluster '$CLUSTER_NAME'. Please check your inventory and cluster name."
    exit 1
fi

online_hosts=()
offline_hosts=()

for host in "${hosts[@]}"; do
    echo "--- Checking host: $host ---"
    start_time=$SECONDS
    is_online=false

    while true; do
        ping_output=$(ping -c 1 -W 5 "$host" 2>&1)
        if [ $? -eq 0 ]; then
            elapsed_time=$((SECONDS - start_time))
            echo "$host is UP! (Responded after ${elapsed_time} seconds)"
            echo "Ping output: $ping_output"
            online_hosts+=("$host")
            is_online=true
            break
        fi
        elapsed_time=$((SECONDS - start_time))
        if (( elapsed_time > TIMEOUT_SECONDS )); then
            echo "$host FAILED to respond after $TIMEOUT_SECONDS seconds."
            echo "Last ping output: $ping_output"
            offline_hosts+=("$host")
            break
        fi
        echo "Pinging $host... Status: Down (waiting $PING_INTERVAL_SECONDS s)"
        sleep $PING_INTERVAL_SECONDS
    done
    echo ""
done

echo "================================================="
echo "### Final Reboot Status Summary"
echo "================================================="
echo ""
echo "Online Hosts (${#online_hosts[@]}):"
if [ ${#online_hosts[@]} -gt 0 ]; then
    printf " - %s\n" "${online_hosts[@]}"
else
    echo " - None"
fi
echo ""
echo "Failed/Offline Hosts (${#offline_hosts[@]}):"
if [ ${#offline_hosts[@]} -gt 0 ]; then
    printf " - %s\n" "${offline_hosts[@]}"
else
    echo " - None"
fi
echo ""