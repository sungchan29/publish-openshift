#!/bin/bash

### Enable strict mode
set -euo pipefail

### Initialize variables
OUTPUT_DIR="./pod-resources"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV_FILE="$OUTPUT_DIR/pod-resources-$TIMESTAMP.csv"
LOG_FILE="$OUTPUT_DIR/pod-resources-$TIMESTAMP.log"

mkdir -p $OUTPUT_DIR

### Logging function
log() {
    local level="$1"
    local msg="$2"
    echo "[$level] $(date +'%Y-%m-%d %H:%M:%S') $msg" | tee -a "$LOG_FILE"
}

### Check disk space
check_disk_space() {
    local dir="$1"
    df -h "$dir" | tail -n 1 | awk '{if ($5+0 > 90) {print "[ERROR] Insufficient disk space in '"$dir"' (" $5 "). Exiting..."; exit 1}}' >&2 || {
        log "ERROR" "Insufficient disk space in $dir"
        exit 1
    }
}

### Validate dependencies
if ! command -v oc >/dev/null 2>&1; then
    log "ERROR" "'oc' command not found. Please install OpenShift CLI. Exiting..."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR" "'jq' command not found. Please install jq. Exiting..."
    exit 1
fi

### Verify oc login
if ! oc whoami >/dev/null 2>&1; then
    log "ERROR" "Not logged in to OpenShift cluster. Please run 'oc login' first. Exiting..."
    exit 1
fi
log "INFO" "Logged in as $(oc whoami)"

### Create output directory
mkdir -p "$OUTPUT_DIR" || {
    log "ERROR" "Failed to create output directory $OUTPUT_DIR"
    exit 1
}
log "INFO" "Created output directory: $OUTPUT_DIR"

### Check disk space
check_disk_space "$OUTPUT_DIR"

### Initialize CSV file with header
echo "Namespace,Pod,Node,CPU Request (m),CPU Limit (m),Memory Request (MB),Memory Limit (MB)" > "$CSV_FILE"
log "INFO" "Initialized CSV file: $CSV_FILE"

### Function to process a single pod
process_pod() {
    local namespace="$1"
    local pod="$2"
    local json_data
    local node="N/A"
    local cpu_request="N/A"
    local cpu_limit="N/A"
    local mem_request="N/A"
    local mem_limit="N/A"

    ### Get pod details in JSON
    json_data=$(oc get pod -n "$namespace" "$pod" -o json 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log "WARN" "Failed to get details for pod $pod in namespace $namespace. Skipping..."
        return
    fi

    ### Extract node name
    node=$(echo "$json_data" | jq -r '.spec.nodeName // "N/A"')

    ### Extract resource requests and limits using jq
    local containers
    containers=$(echo "$json_data" | jq -c '.spec.containers[]')

    ### Aggregate resources across all containers
    local total_cpu_request=0
    local total_cpu_limit=0
    local total_mem_request=0
    local total_mem_limit=0

    while IFS= read -r container; do
        ### CPU Requests
        local cpu_req
        cpu_req=$(echo "$container" | jq -r '.resources.requests.cpu // "0"')
        if [[ "$cpu_req" != "0" ]]; then
            if [[ "$cpu_req" =~ ^([0-9]+)m$ ]]; then
                total_cpu_request=$((total_cpu_request + ${BASH_REMATCH[1]}))
            elif [[ "$cpu_req" =~ ^([0-9]+)$ ]]; then
                total_cpu_request=$((total_cpu_request + ${BASH_REMATCH[1]} * 1000))
            fi
        fi

        ### CPU Limits
        local cpu_lim
        cpu_lim=$(echo "$container" | jq -r '.resources.limits.cpu // "0"')
        if [[ "$cpu_lim" != "0" ]]; then
            if [[ "$cpu_lim" =~ ^([0-9]+)m$ ]]; then
                total_cpu_limit=$((total_cpu_limit + ${BASH_REMATCH[1]}))
            elif [[ "$cpu_lim" =~ ^([0-9]+)$ ]]; then
                total_cpu_limit=$((total_cpu_limit + ${BASH_REMATCH[1]} * 1000))
            fi
        fi

        ### Memory Requests
        local mem_req
        mem_req=$(echo "$container" | jq -r '.resources.requests.memory // "0"')
        if [[ "$mem_req" != "0" ]]; then
            if [[ "$mem_req" =~ ^([0-9]+)([KMG]i?)$ ]]; then
                local value=${BASH_REMATCH[1]}
                local unit=${BASH_REMATCH[2]}
                case "$unit" in
                    Ki) total_mem_request=$((total_mem_request + (value / 1024))) ;;
                    Mi) total_mem_request=$((total_mem_request + value)) ;;
                    Gi) total_mem_request=$((total_mem_request + (value * 1024))) ;;
                    *) log "WARN" "Unknown memory unit '$unit' for pod $namespace/$pod" ;;
                esac
            elif [[ "$mem_req" =~ ^([0-9]+)$ ]]; then
                total_mem_request=$((total_mem_request + ${BASH_REMATCH[1]}))
            fi
        fi

        ### Memory Limits
        local mem_lim
        mem_lim=$(echo "$container" | jq -r '.resources.limits.memory // "0"')
        if [[ "$mem_lim" != "0" ]]; then
            if [[ "$mem_lim" =~ ^([0-9]+)([KMG]i?)$ ]]; then
                local value=${BASH_REMATCH[1]}
                local unit=${BASH_REMATCH[2]}
                case "$unit" in
                    Ki) total_mem_limit=$((total_mem_limit + (value / 1024))) ;;
                    Mi) total_mem_limit=$((total_mem_limit + value)) ;;
                    Gi) total_mem_limit=$((total_mem_limit + (value * 1024))) ;;
                    *) log "WARN" "Unknown memory unit '$unit' for pod $namespace/$pod" ;;
                esac
            elif [[ "$mem_lim" =~ ^([0-9]+)$ ]]; then
                total_mem_limit=$((total_mem_limit + ${BASH_REMATCH[1]}))
            fi
        fi
    done <<< "$containers"

    ### Set output values
    if [[ $total_cpu_request -gt 0 ]]; then
        cpu_request="$total_cpu_request"
    fi
    if [[ $total_cpu_limit -gt 0 ]]; then
        cpu_limit="$total_cpu_limit"
    fi
    if [[ $total_mem_request -gt 0 ]]; then
        mem_request="$total_mem_request"
    fi
    if [[ $total_mem_limit -gt 0 ]]; then
        mem_limit="$total_mem_limit"
    fi

    ### Escape commas in values to prevent CSV issues
    namespace=$(echo "$namespace" | sed 's/,/\\,/g')
    pod=$(echo "$pod" | sed 's/,/\\,/g')
    node=$(echo "$node" | sed 's/,/\\,/g')
    cpu_request=$(echo "$cpu_request" | sed 's/,/\\,/g')
    cpu_limit=$(echo "$cpu_limit" | sed 's/,/\\,/g')
    mem_request=$(echo "$mem_request" | sed 's/,/\\,/g')
    mem_limit=$(echo "$mem_limit" | sed 's/,/\\,/g')

    ### Append to CSV
    echo "$namespace,$pod,$node,$cpu_request,$cpu_limit,$mem_request,$mem_limit" >> "$CSV_FILE"
    log "INFO" "Processed pod: $namespace/$pod on node $node"
}

### Main logic
log "INFO" "Starting pod resource collection for OpenShift cluster"

### Get all running pods across all namespaces
log "INFO" "Fetching list of running pods..."
mapfile -t pods < <(oc get pods --all-namespaces --field-selector=status.phase=Running -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')

if [[ ${#pods[@]} -eq 0 ]]; then
    log "WARN" "No running pods found in the cluster."
    exit 0
fi

log "INFO" "Found ${#pods[@]} running pods"

### Process each pod
for pod_info in "${pods[@]}"; do
    read -r namespace pod_name <<< "$pod_info"
    process_pod "$namespace" "$pod_name"
done

### Verify CSV file
if [[ ! -f "$CSV_FILE" ]] || [[ ! -s "$CSV_FILE" ]]; then
    log "ERROR" "CSV file $CSV_FILE was not created or is empty."
    exit 1
fi

### Log results
log "INFO" "Resource collection completed. CSV file: $CSV_FILE"
log "INFO" "CSV file size: $(ls -lh "$CSV_FILE" | awk '{print $5}')"
log "INFO" "Log file: $LOG_FILE"
wc -l "$CSV_FILE" | awk '{print "[INFO] Total pods processed: " $1-1}' | tee -a "$LOG_FILE"

### List directory structure
if command -v tree >/dev/null 2>&1; then
    log "INFO" "Directory structure of '$OUTPUT_DIR':"
    tree "$OUTPUT_DIR" | tee -a "$LOG_FILE" || log "WARN" "tree command failed"
else
    log "INFO" "'tree' command not found, listing files with ls:"
    ls -lR "$OUTPUT_DIR" | tee -a "$LOG_FILE" || log "WARN" "ls command failed"
fi