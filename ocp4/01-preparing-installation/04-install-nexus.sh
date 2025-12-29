#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
NEXUS_HOST_NAME="registry.cloudpang.lan"
BASE_HOME="/opt/nexus"

### Data Directories
NEXUS_REAL_DATA_DIR="/data/nexus"

### Images
NEXUS_IMAGE="docker.io/sonatype/nexus3:latest"
NEXUS_CONTAINER_NAME="nexus"

### 2. Certificate Configuration
### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt, key
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
NEXUS_CUSTOM_CERT=""
NEXUS_CUSTOM_KEY=""

### 3. Port Settings (HTTPS ONLY)
NEXUS_PUBLISH_HTTPS="172.16.120.28:8443"

### [Dynamic Custom Ports]
NEXUS_PUBLISH_CUSTOM_MAP=(
    "172.16.120.28:5000:5000"
    "172.16.120.28:5001:5001"
)

### 4. Internal Ports
NEXUS_INT_HTTPS="8443"

### 5. Resource Limits
### Use MB Integer for calculation
### Total Container Memory: 4096MB (4GB)
### -> Heap will be auto-set to ~50% (2048MB)
### -> DirectMemory will be auto-set to ~30% (1228MB)
### -> Remaining ~20% for OS/Metaspace overhead
NEXUS_MEM_MB="4096"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

get_port_number() {
    local input=$1
    local default=$2
    if [[ -z "$input" ]]; then echo "$default"; elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$default"; else echo "${input##*:}"; fi
}

get_podman_port_arg() {
    local config_val=$1; local internal_port=$2; local is_optional=$3
    if [[ -z "$config_val" ]]; then
        [[ "$is_optional" == "true" ]] && echo "" || echo "-p ${internal_port}:${internal_port}"
    elif [[ "$config_val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "-p ${config_val}:${internal_port}:${internal_port}"
    else
        echo "-p ${config_val}:${internal_port}"
    fi
}

stop_and_remove_container() {
    local ctr_name=$1
    local svc_name="container-${ctr_name}.service"
    printf "%-8s%-80s\n" "[INFO]" "  > Stopping and cleaning up '$ctr_name'..."
    if systemctl is-active --quiet "$svc_name"; then
        printf "%-8s%-80s\n" "[INFO]" "    - Found active Systemd service. Stopping via systemctl..."
        systemctl stop "$svc_name"
    elif podman ps --format "{{.Names}}" | grep -q "^${ctr_name}$"; then
        printf "%-8s%-80s\n" "[INFO]" "    - Found running Podman container. Attempting graceful stop (timeout 60s)..."
        if podman stop --time=60 "$ctr_name" >/dev/null 2>&1; then
            printf "%-8s%-80s\n" "[INFO]" "    - Container stopped gracefully."
            podman rm "$ctr_name" >/dev/null 2>&1
        else
            printf "%-8s%-80s\n" "[WARN]" "    - Graceful stop timed out or failed. Force removing..."
            podman rm -f "$ctr_name" >/dev/null 2>&1
        fi
    else
        podman rm -f "$ctr_name" >/dev/null 2>&1
    fi
}

cleanup_systemd_services() {
    local ctr_name=$1
    local svc_name="container-${ctr_name}.service"

    if systemctl is-enabled --quiet "$svc_name"; then
        systemctl disable "$svc_name" >/dev/null 2>&1
    fi
    if [[ -f "/etc/systemd/system/$svc_name" ]]; then
        rm -f "/etc/systemd/system/$svc_name"
    fi
    systemctl daemon-reload
    systemctl reset-failed
}

### Log-based Health Check for Nexus
wait_for_container() {
    local ctr_name=$1
    local max_retries=60
    local sleep_time=5
    local count=0

    echo -n "[INFO]    > Waiting for $ctr_name to be healthy (Checking Logs): "
    while [[ $count -lt $max_retries ]]; do
        local state_status=$(podman inspect "$ctr_name" --format '{{.State.Status}}' 2>/dev/null)
        if [[ "$state_status" == "running" ]]; then
            if podman logs "$ctr_name" 2>&1 | grep -q "Started Sonatype Nexus"; then
                echo " [OK]"
                return 0
            fi
        fi
        echo -n "."
        sleep $sleep_time
        ((count++))
    done
    echo ""
    printf "%-8s%-80s\n" "[WARN]" "  > Warning: Timed out waiting for $ctr_name to become ready (after $((max_retries * sleep_time)) seconds)."
    local final_inspect=$(podman inspect "$ctr_name" --format json 2>/dev/null)
    if [[ -n "$final_inspect" ]]; then
        local final_state=$(echo "$final_inspect" | jq -r '.[0].State.Status' 2>/dev/null)
        printf "%-8s%-80s\n" "[WARN]" "    Current container state at timeout:"
        printf "%-8s%-80s\n" "[WARN]" "      State.Status       : $final_state"
    else
        printf "%-8s%-80s\n" "[WARN]" "    Current container state at timeout: Container not found or inspect failed."
    fi
    printf "%-8s%-80s\n" "[WARN]" "  > Container logs (last 20 lines):"
    podman logs "$ctr_name" 2>/dev/null | tail -n 20 || printf "%-8s%-80s\n" "[WARN]" "(No logs available)"
    exit 1
}

check_command() { if [[ $1 -ne 0 ]]; then printf "%-8s%-80s\n" "[ERROR]" "Critical Error. Exit Code $1. Aborting."; exit $1; fi; }

### 1. Prerequisites
if [[ $EUID -ne 0 ]]; then printf "%-8s%-80s\n" "[ERROR]" "Run as root."; exit 1; fi
for cmd in podman openssl; do
    if ! command -v $cmd &> /dev/null; then
        printf "%-8s%-80s\n" "[WARN]" "'$cmd' not found. This script requires $cmd."
    fi
done
if [[ -z "$NEXUS_PUBLISH_HTTPS" ]]; then printf "%-8s%-80s\n" "[ERROR]" "HTTPS must be set."; exit 1; fi

if [[ -n "$NEXUS_REAL_DATA_DIR" ]] && [[ "$NEXUS_REAL_DATA_DIR" != "$BASE_HOME" ]]; then
    REAL_DATA_PATH="${NEXUS_REAL_DATA_DIR}"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${BASE_HOME}/nexus-data"
    IS_SPLIT_STORAGE=false
fi

### 2. Operation Mode
if [[ -d "$REAL_DATA_PATH" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "=================================================================="
    printf "%-8s%-80s\n" "[INFO]" " [SELECT MODE]"
    printf "%-8s%-80s\n" "[INFO]" "=================================================================="
    printf "%-8s%-80s\n" "[INFO]" " 1) Fresh Install (WARNING: Wipes ALL Data)"
    printf "%-8s%-80s\n" "[INFO]" " 2) Update / Reconfigure (Keeps Data, Refreshes Certs/Containers)"
    read -p "[INPUT]  Select [1 or 2]: " OP_MODE

    [[ "$OP_MODE" != "1" && "$OP_MODE" != "2" ]] && exit 1
    printf "%-8s%-80s\n" "[INFO]" ""
fi

### 3. Directory & Resource Setup
printf "%-8s%-80s\n" "[INFO]" "Directory & Resource Setup"
printf "%-8s%-80s\n" "[INFO]" "  > Resolving certificates..."
if [[ -n "$NEXUS_CUSTOM_CERT" ]]; then SOURCE_CERT="$NEXUS_CUSTOM_CERT"; else SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt"; fi
if [[ -n "$NEXUS_CUSTOM_KEY" ]]; then SOURCE_KEY="$NEXUS_CUSTOM_KEY"; else SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key"; fi
if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then printf "%-8s%-80s\n" "[ERROR]" "Cert files not found."; exit 1; fi

### Cleanup Logic
printf "%-8s%-80s\n" "[INFO]" "  > Cleaning up existing containers..."
stop_and_remove_container "$NEXUS_CONTAINER_NAME"

printf "%-8s%-80s\n" "[INFO]" "  > Cleaning up Systemd services..."
cleanup_systemd_services "$NEXUS_CONTAINER_NAME"

### Directory Setup
printf "%-8s%-80s\n" "[INFO]" "  > Setting up directory structure..."
LOCAL_SSL_PATH="${BASE_HOME}/nexus-etc-ssl"
NEXUS_ENV_PATH="${BASE_HOME}/nexus-env"

if [[ "$OP_MODE" == "1" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    - Cleaning Real Data..."
    rm -rf "${REAL_DATA_PATH:?}"/*

    if [[ -d "$BASE_HOME" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    - Cleaning Configs..."
        rm -rf "${BASE_HOME:?}"/*
    fi
fi

### Explicitly create subdirectories required by Nexus to avoid mkdir permission errors
mkdir -p "$LOCAL_SSL_PATH" \
         "${REAL_DATA_PATH}/etc" \
         "${REAL_DATA_PATH}/log" \
         "${REAL_DATA_PATH}/tmp" \
         "${REAL_DATA_PATH}/audit" \
         "${REAL_DATA_PATH}/javaprefs" \
         "$NEXUS_ENV_PATH"

if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    - Creating Symlink for Data..."
    LINK_DATA_PATH="${BASE_HOME}/nexus-data"
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
fi

printf "%-8s%-80s\n" "[INFO]" "  > Setting Permissions (Owner 200:200)..."
chown -R 200:200 "${BASE_HOME}" "${REAL_DATA_PATH}" "${LOCAL_SSL_PATH}" "${NEXUS_ENV_PATH}"

printf "%-8s%-80s\n" "[INFO]" "  > Setting Permissions (SELinux Context)..."
chcon -R -t container_file_t "${REAL_DATA_PATH}" "${LOCAL_SSL_PATH}" 2>/dev/null || true

### Keystore Generation
JKS_PATH="${LOCAL_SSL_PATH}/keystore.jks"
PKCS12_PATH="${LOCAL_SSL_PATH}/nexus.p12"

### Ensure Keystore exists or regenerate in Mode 2
printf "%-8s%-80s\n" "[INFO]" "Keystore Generation"
### Clean up existing files
rm -f "$PKCS12_PATH" "$JKS_PATH"

### [Step 1] Convert certificates to PKCS12 format (OpenSSL)
printf "%-8s%-80s\n" "[INFO]" "  > [1/2] Converting certificates to PKCS12 format (OpenSSL)..."
openssl pkcs12 -export -in "$SOURCE_CERT" -inkey "$SOURCE_KEY" -out "$PKCS12_PATH" -name nexus -passout pass:password

if [[ ! -f "$PKCS12_PATH" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Failed to create PKCS12 file. Check certificates."
    exit 1
fi
chown 200:200 "$PKCS12_PATH"

### [Step 2] Import PKCS12 to JKS format (Podman/Keytool)
printf "%-8s%-80s\n" "[INFO]" "  > [2/2] Importing PKCS12 to JKS format (Podman/Keytool)..."
podman run --rm -v "${LOCAL_SSL_PATH}:/ssl:Z" --entrypoint keytool "$NEXUS_IMAGE" \
    -importkeystore -srckeystore "/ssl/nexus.p12" -srcstoretype PKCS12 \
    -destkeystore "/ssl/keystore.jks" -deststoretype JKS \
    -srcstorepass password -deststorepass password >/dev/null 2>&1

if [[ ! -f "$JKS_PATH" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Failed to create JKS keystore. Check Podman logs or permissions."
    exit 1
fi
chown 200:200 "$JKS_PATH"

printf "%-8s%-80s\n" "[INFO]" "  > Keystore generated successfully."

### 4. Generating Nexus Configuration
printf "%-8s%-80s\n" "[INFO]" "Generating Nexus Configuration..."

### Use single quotes to prevent Bash from expanding ${jetty.etc}
JETTY_XML_LIST='${jetty.etc}/jetty.xml,${jetty.etc}/jetty-requestlog.xml,${jetty.etc}/jetty-https.xml'
PROPERTY_FILE="${REAL_DATA_PATH}/etc/nexus.properties"

cat <<EOF > "$PROPERTY_FILE"
nexus-args=${JETTY_XML_LIST}
application-port-ssl=${NEXUS_INT_HTTPS}
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF
chown 200:200 "$PROPERTY_FILE"

### Create ENV file for runtime
### Calculate JVM Memory safely to avoid OOM
###   Heap (Xms/Xmx) = 50% of Container Memory
###   Direct Memory  = 30% of Container Memory
MEM_HEAP=$(( NEXUS_MEM_MB * 50 / 100 ))
MEM_DIRECT=$(( NEXUS_MEM_MB * 30 / 100 ))

printf "%-8s%-80s\n" "[INFO]" "  > Memory Config: Container=${NEXUS_MEM_MB}m | Heap=${MEM_HEAP}m | Direct=${MEM_DIRECT}m"

### Added -Djava.util.prefs.userRoot to ensure prefs utilize writable volume
echo "INSTALL4J_ADD_VM_PARAMS=-Xms${MEM_HEAP}m -Xmx${MEM_HEAP}m -XX:MaxDirectMemorySize=${MEM_DIRECT}m -Djava.util.prefs.userRoot=/nexus-data/javaprefs" > "${NEXUS_ENV_PATH}/nexus-runtime.env"
chmod 600 "${NEXUS_ENV_PATH}/nexus-runtime.env"
chown 200:200 "${NEXUS_ENV_PATH}/nexus-runtime.env"

### 5. Firewall Configuration
printf "%-8s%-80s\n" "[INFO]" "Firewall Configuration"
printf "%-8s%-80s\n" "[INFO]" "  > Configuring Firewall rules..."
FW_PORTS=($(get_port_number "$NEXUS_PUBLISH_HTTPS" ""))
for MAPPING in "${NEXUS_PUBLISH_CUSTOM_MAP[@]}"; do
    [[ -n "$MAPPING" ]] && FW_PORTS+=($(echo "$MAPPING" | awk -F: '{print $(NF-1)}'))
done

for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        semanage port -a -t http_port_t -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

### 6. Initial Container Deployment
printf "%-8s%-80s\n" "[INFO]" "Initial Container Deployment"
printf "%-8s%-80s\n" "[INFO]" "  > Initializing Nexus container..."
HTTPS_ARG=$(get_podman_port_arg "$NEXUS_PUBLISH_HTTPS" "$NEXUS_INT_HTTPS" "false")
CUSTOM_PORT_ARGS=()
for MAPPING in "${NEXUS_PUBLISH_CUSTOM_MAP[@]}"; do
    [[ -n "$MAPPING" ]] && CUSTOM_PORT_ARGS+=("-p" "$MAPPING")
done

### Build Podman command array for better handling
CMD_NEXUS=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$NEXUS_CONTAINER_NAME"
    "--cpus" "4"
    "--memory" "${NEXUS_MEM_MB}m"
    "--env-file" "${NEXUS_ENV_PATH}/nexus-runtime.env"
    "-v" "${REAL_DATA_PATH}:/nexus-data:Z"
    "-v" "${LOCAL_SSL_PATH}:/opt/sonatype/nexus/etc/ssl:Z"
)
if [[ -n "${HTTPS_ARG:-}" ]]; then
    CMD_NEXUS+=($HTTPS_ARG)
fi
if [[ -n "${CUSTOM_PORT_ARGS[*]}" ]]; then
    CMD_NEXUS+=("${CUSTOM_PORT_ARGS[@]}")
fi
CMD_NEXUS+=("$NEXUS_IMAGE")

CMD_NEXUS_STR="${CMD_NEXUS[*]}"

printf "%-8s%-80s\n" "[INFO]" "  > Executing: $NEXUS_CONTAINER_NAME"
printf "%-8s%-80s\n" "[INFO]" "    >  $CMD_NEXUS_STR" # Debug
"${CMD_NEXUS[@]}"
wait_for_container "$NEXUS_CONTAINER_NAME"

### 7. Systemd Integration
printf "%-8s%-80s\n" "[INFO]" "Systemd Integration"
printf "%-8s%-80s\n" "[INFO]" "  > Generating Systemd unit files..."

cd /etc/systemd/system
podman generate systemd --new --files --name "$NEXUS_CONTAINER_NAME" >/dev/null
systemctl daemon-reload
systemctl enable "container-${NEXUS_CONTAINER_NAME}"

### 8. Helper Script Generation
printf "%-8s%-80s\n" "[INFO]" "Helper Script Generation"
printf "%-8s%-80s\n" "[INFO]" "  > Creating Start Script..."
START_SCRIPT="${BASE_HOME}/start-nexus.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
echo "Starting Nexus..."
systemctl start container-${NEXUS_CONTAINER_NAME}
echo "Done."
EOF
chmod 700 "$START_SCRIPT"

printf "%-8s%-80s\n" "[INFO]" "  > Creating Stop Script..."
STOP_SCRIPT="${BASE_HOME}/stop-nexus.sh"
cat <<EOF > "$STOP_SCRIPT"
#!/bin/bash
echo "Stopping Nexus..."
systemctl stop container-${NEXUS_CONTAINER_NAME}
echo "Done."
EOF
chmod 700 "$STOP_SCRIPT"

### 9. Restart Nexus (Handover to Systemd)
printf "%-8s%-80s\n" "[INFO]" "Service Handover (Restart)"
printf "%-8s%-80s\n" "[INFO]" "  > Transitioning to Systemd management..."

stop_and_remove_container "$NEXUS_CONTAINER_NAME"

printf "%-8s%-80s\n" "[INFO]" "  > Starting $NEXUS_CONTAINER_NAME via Systemd..."
systemctl start "container-${NEXUS_CONTAINER_NAME}.service"
wait_for_container "$NEXUS_CONTAINER_NAME"

### 10. Display Info
ADMIN_PASS_FILE="${REAL_DATA_PATH}/admin.password"
DISP_PORT=$(get_port_number "$NEXUS_PUBLISH_HTTPS" "$NEXUS_INT_HTTPS")

printf "%-8s%-80s\n" "[INFO]" "----------------------------------------------------------------"
printf "%-8s%-80s\n" "[INFO]" " [SUCCESS] Installation Complete"
printf "%-8s%-80s\n" "[INFO]" "----------------------------------------------------------------"
printf "%-8s%-80s\n" "[INFO]" "  URL: https://${NEXUS_HOST_NAME}:${DISP_PORT}"
if [[ "$OP_MODE" != "2" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "  Initial Password File: $ADMIN_PASS_FILE"
    if [[ -f "$ADMIN_PASS_FILE" ]]; then
        cat "$ADMIN_PASS_FILE"
    fi
fi
echo ""