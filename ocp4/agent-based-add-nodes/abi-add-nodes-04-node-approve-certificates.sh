#!/bin/bash

### Enable strict mode
set -euo pipefail

### Set up logging
log_file="$(basename "$0" .sh).log"

### Logging function to format and append logs using tee
log() {
    local level="$1"
    local message="$2"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $message" | tee -a "$log_file"
}

### Initialize logging
echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Logging to $log_file" > $log_file

### Source the configuration file
config_file="$(dirname "$(realpath "$0")")/abi-add-nodes-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    log "ERROR" "Cannot access '$config_file'. File or directory does not exist."
    exit 1
fi
if ! source "$config_file"; then
    log "ERROR" "Failed to source '$config_file'. Check file syntax or permissions."
    exit 1
fi

### Validate required variables
validate_non_empty "CLUSTER_NAME" "$CLUSTER_NAME"
validate_non_empty "BASE_DOMAIN" "$BASE_DOMAIN"
validate_non_empty "API_SERVER" "$API_SERVER"
validate_non_empty "NODE_INFO_LIST" "${NODE_INFO_LIST[*]}"
validate_non_empty "MAX_ATTEMPTS" "$MAX_ATTEMPTS"
validate_non_empty "CHECK_INTERVAL" "$CHECK_INTERVAL"

### Construct expected node names (e.g., wrk01.cloudpang.tistory.disconnected)
node_names=()
for node_info in "${NODE_INFO_LIST[@]}"; do
    # Split node_info by '--' and extract the second field (node name, e.g., wrk01)
    node_short_name=$(echo "$node_info" | awk -F'--' '{print $2}')
    # Combine with CLUSTER_NAME and BASE_DOMAIN
    node_full_name="${node_short_name}.${CLUSTER_NAME}.${BASE_DOMAIN}"
    node_names+=("$node_full_name")
done

### Log the nodes being monitored
log "INFO" "Monitoring CSRs and node status for the following nodes:"
for node in "${node_names[@]}"; do
    log "INFO" "$node"
done

### Function to approve pending CSRs
approve_csrs() {
    log "INFO" "Checking for pending CSRs..."
    pending_csrs=$(./oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || echo "")
    if [ -n "$pending_csrs" ]; then
        log "INFO" "Found pending CSRs:"
        while IFS= read -r csr; do
            [ -n "$csr" ] && log "INFO" "$csr"
        done <<< "$pending_csrs"
        log "INFO" "Approving CSRs..."
        if echo "$pending_csrs" | xargs --no-run-if-empty ./oc adm certificate approve 2>&1 | tee -a "$log_file"; then
            log "INFO" "CSRs approved successfully."
        else
            log "ERROR" "Failed to approve some CSRs."
        fi
    else
        log "INFO" "No pending CSRs found."
    fi
}

### Function to check if all nodes are Ready
check_nodes_ready() {
    all_ready=true
    for node in "${node_names[@]}"; do
        node_status=$(./oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
        if [ "$node_status" != "True" ]; then
            log "INFO" "Node $node is not Ready (Status: $node_status)"
            all_ready=false
        else
            log "INFO" "Node $node is Ready"
        fi
    done
    $all_ready
}

### Main loop: Approve CSRs and check node status

### Login to cluster
login_to_cluster

attempt=1
while [ $attempt -le $MAX_ATTEMPTS ]; do
    log "INFO" "Attempt $attempt of $MAX_ATTEMPTS"

    # Approve any pending CSRs
    approve_csrs

    # Check if all nodes are Ready
    if check_nodes_ready; then
        log "INFO" "All nodes are Ready. Exiting successfully."
        exit 0
    fi

    # Wait before the next attempt
    log "INFO" "Waiting $CHECK_INTERVAL seconds before the next check..."
    sleep $CHECK_INTERVAL
    ((attempt++))
done

### If max attempts reached, exit with error
log "ERROR" "Not all nodes reached Ready state after $MAX_ATTEMPTS attempts."
exit 1