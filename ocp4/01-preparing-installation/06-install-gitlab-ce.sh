#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
GITLAB_HOST_NAME="gitlab.cloudpang.lan"
BASE_HOME="/opt/gitlab"

### Data Directories
GITLAB_REAL_DATA_DIR="/data/gitlab"

### Custom Assets
GITLAB_ASSET_HOME="/opt/gitlab-assets"

GITLAB_IMAGE="docker.io/gitlab/gitlab-ce:latest"
GITLAB_CONTAINER_NAME="gitlab"

### 2. Certificate Configuration
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
GITLAB_CUSTOM_CERT=""
GITLAB_CUSTOM_KEY=""

### 3. Port Settings
GITLAB_PUBLISH_HTTP=""
GITLAB_PUBLISH_HTTPS="172.16.120.28:7443"
GITLAB_PUBLISH_SSH="172.16.120.28:2222"

### 4. Internal Ports
GITLAB_INT_SSH="22"

### 5. Resource Limits
GITLAB_RES="--cpus 4 --memory 8g"

### 6. Puma Configuration
PUMA_PROC_NUM="4"
PUMA_PER_WKR_MAX_MEM_MB="1200"

### 7. Custom Error Pages
GITLAB_CUSTOM_ERR_PATH="${GITLAB_ASSET_HOME}/error-pages"
ERR_CODES=("400" "402" "403" "404" "422" "500" "502" "503")

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

get_port_number() {
    local input=$1
    local default=$2
    if [[ -z "$input" ]]; then echo "$default"; elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$default"; else echo "${input##*:}"; fi
}

get_podman_port_arg() {
    local input=$1; local internal_port=$2; local default_port=$3
    if [[ -z "$input" ]]; then echo ""
    elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "-p ${input}:${default_port}:${internal_port}"
    else echo "-p ${input}:${internal_port}"; fi
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
            printf "%-8s%-80s\n" "[INFO]" "    - Graceful stop timed out or failed. Force removing..."
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

### User provided wait function
wait_for_container() {
    local ctr_name=$1
    local max_retries=60
    local sleep_time=5
    local count=0

    echo -n "[INFO]    > Waiting for $ctr_name to be healthy: "
    while [[ $count -lt $max_retries ]]; do
        local inspect_json=$(podman inspect "$ctr_name" --format json 2>/dev/null)
        if [[ -n "$inspect_json" ]]; then
            local state_status=$(echo "$inspect_json" | jq -r '.[0].State.Status' 2>/dev/null)
            local health_status=$(echo "$inspect_json" | jq -r '.[0].State.Health.Status // "none"' 2>/dev/null)
            if [[ "$state_status" == "running" ]] && [[ "$health_status" == "healthy" || "$health_status" == "none" ]]; then
                echo " [OK]"
                return 0
            fi
        fi
        echo -n "."
        sleep $sleep_time
        ((count++))
    done

    printf "%-8s%-80s\n" "[INFO]" "  > Warning: Timed out waiting for $ctr_name to become ready (after $((max_retries * sleep_time)) seconds)."
    local final_inspect=$(podman inspect "$ctr_name" --format json 2>/dev/null)
    if [[ -n "$final_inspect" ]]; then
        local final_state=$(echo "$final_inspect" | jq -r '.[0].State.Status' 2>/dev/null)
        local final_health=$(echo "$final_inspect" | jq -r '.[0].State.Health.Status // "none"' 2>/dev/null)
        printf "%-8s%-80s\n" "[INFO]" "    Current container state at timeout:"
        printf "%-8s%-80s\n" "[INFO]" "      State.Status       : $final_state"
        printf "%-8s%-80s\n" "[INFO]" "      State.Health.Status: $final_health"
    else
        printf "%-8s%-80s\n" "[INFO]" "    Current container state at timeout: Container not found or inspect failed."
    fi
    printf "%-8s%-80s\n" "[INFO]" "  > Container logs (last 20 lines):"
    podman logs "$ctr_name" 2>/dev/null | tail -n 20 || printf "%-8s%-80s\n" "[INFO]" "(No logs available)"
    if [[ -n "$final_inspect" ]] && echo "$final_inspect" | jq -e '.[0].State.Health.Log' >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[INFO]" "Latest healthcheck log entry:"
        echo "$final_inspect" | jq '.[][0].State.Health.Log[-1]' 2>/dev/null | jq . 2>/dev/null || \
        echo "$final_inspect" | jq -r '.[][0].State.Health.Log[-1]' 2>/dev/null
    fi
    exit 1
}

check_command() { if [[ $1 -ne 0 ]]; then echo "[CRITICAL ERROR] Exit Code $1. Aborting."; exit $1; fi; }

### 1. Prerequisites
if [[ $EUID -ne 0 ]]; then printf "%-8s%-80s\n" "[ERROR]" "Run as root."; exit 1; fi
if [[ -z "$GITLAB_PUBLISH_HTTP" ]] && [[ -z "$GITLAB_PUBLISH_HTTPS" ]]; then printf "%-8s%-80s\n" "[ERROR]" "HTTP or HTTPS must be set."; exit 1; fi

if [[ -n "$GITLAB_REAL_DATA_DIR" ]] && [[ "$GITLAB_REAL_DATA_DIR" != "$BASE_HOME" ]]; then
    REAL_DATA_PATH="${GITLAB_REAL_DATA_DIR}/data"
    REAL_LOG_PATH="${GITLAB_REAL_DATA_DIR}/logs"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${BASE_HOME}/data"
    REAL_LOG_PATH="${BASE_HOME}/logs"
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
if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    if [[ -n "$GITLAB_CUSTOM_CERT" ]]; then SOURCE_CERT="$GITLAB_CUSTOM_CERT"; else SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.crt"; fi
    if [[ -n "$GITLAB_CUSTOM_KEY" ]]; then SOURCE_KEY="$GITLAB_CUSTOM_KEY"; else SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.key"; fi
    if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then printf "%-8s%-80s\n" "[ERROR]" "Cert files not found."; exit 1; fi
fi

### Cleanup Logic
printf "%-8s%-80s\n" "[INFO]" "  > Cleaning up existing containers..."
stop_and_remove_container "$GITLAB_CONTAINER_NAME"

printf "%-8s%-80s\n" "[INFO]" "  > Cleaning up Systemd services..."
cleanup_systemd_services "$GITLAB_CONTAINER_NAME"

### Directory Setup
printf "%-8s%-80s\n" "[INFO]" "  > Setting up directory structure..."
LOCAL_CONFIG_PATH="${BASE_HOME}/config"
LOCAL_SSL_PATH="${BASE_HOME}/ssl"
GITLAB_ENV_PATH="${BASE_HOME}/gitlab-env"

if [[ "$OP_MODE" == "1" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    - Cleaning Real Data..."
    rm -rf "${REAL_DATA_PATH:?}"/* "${REAL_LOG_PATH:?}"/*

    if [[ -d "$BASE_HOME" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    - Cleaning Configs..."
        rm -rf "${BASE_HOME:?}"/*
    fi
fi

mkdir -p "$LOCAL_CONFIG_PATH" "$LOCAL_SSL_PATH" "$REAL_DATA_PATH" "$REAL_LOG_PATH" "$GITLAB_CUSTOM_ERR_PATH" "$GITLAB_ENV_PATH"

if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    - Creating Symlinks..."
    LINK_DATA_PATH="${BASE_HOME}/data"
    LINK_LOG_PATH="${BASE_HOME}/logs"
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
    ln -snf "$REAL_LOG_PATH" "$LINK_LOG_PATH"
fi

printf "%-8s%-80s\n" "[INFO]" "  > Setting Permissions (SELinux Context)..."
chcon -R -t container_file_t "${REAL_DATA_PATH}" "${REAL_LOG_PATH}" "${LOCAL_CONFIG_PATH}" "${LOCAL_SSL_PATH}" 2>/dev/null || true

### 4. Certificate & Configuration Generation
printf "%-8s%-80s\n" "[INFO]" "Certificate & Configuration Generation"
if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "  > Installing Certificates..."
    cp "$SOURCE_CERT" "${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.crt"
    cp "$SOURCE_KEY" "${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.key"
    chmod 644 "${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.crt"
    chmod 600 "${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.key"
fi

printf "%-8s%-80s\n" "[INFO]" "  > Generating GitLab Configuration..."
if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    EXT_HTTPS_PORT=$(get_port_number "$GITLAB_PUBLISH_HTTPS" "443")
    GITLAB_INT_HTTPS="$EXT_HTTPS_PORT"
    if [[ "$EXT_HTTPS_PORT" == "443" ]]; then OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}"; else OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}:${EXT_HTTPS_PORT}"; fi

    NGINX_REDIRECT="false"
    GITLAB_INT_HTTP="80"
    if [[ -n "$GITLAB_PUBLISH_HTTP" ]]; then
        EXT_HTTP_PORT=$(get_port_number "$GITLAB_PUBLISH_HTTP" "80")
        if [[ "$EXT_HTTP_PORT" == "80" ]] && [[ "$EXT_HTTPS_PORT" == "443" ]]; then NGINX_REDIRECT="true"; fi
    fi

    REDIRECT_CONFIG=""
    [[ "$NGINX_REDIRECT" == "true" ]] && REDIRECT_CONFIG="nginx['redirect_http_to_https_port'] = ${GITLAB_INT_HTTP};"

    NGINX_CONFIG="nginx['redirect_http_to_https'] = ${NGINX_REDIRECT}; ${REDIRECT_CONFIG} nginx['listen_port'] = ${GITLAB_INT_HTTPS}; nginx['listen_https'] = true; nginx['ssl_certificate'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.crt'; nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.key'; nginx['custom_gitlab_server_config'] = \"error_page 497 https://\$http_host\$request_uri;\";"
else
    EXT_HTTP_PORT=$(get_port_number "$GITLAB_PUBLISH_HTTP" "80")
    GITLAB_INT_HTTP="$EXT_HTTP_PORT"
    if [[ "$EXT_HTTP_PORT" == "80" ]]; then OMNIBUS_EXTERNAL_URL="http://${GITLAB_HOST_NAME}"; else OMNIBUS_EXTERNAL_URL="http://${GITLAB_HOST_NAME}:${EXT_HTTP_PORT}"; fi
    NGINX_CONFIG="nginx['listen_port'] = ${GITLAB_INT_HTTP}; nginx['listen_https'] = false; nginx['redirect_http_to_https'] = false;"
fi

SSH_PORT=$(get_port_number "$GITLAB_PUBLISH_SSH" "$GITLAB_INT_SSH")

### Combine All Configs
FULL_CONFIG="external_url '${OMNIBUS_EXTERNAL_URL}'; gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}; ${NGINX_CONFIG} puma['worker_processes'] = $PUMA_PROC_NUM; puma['per_worker_max_memory_mb'] = $PUMA_PER_WKR_MAX_MEM_MB;"

### Create ENV file
echo "GITLAB_OMNIBUS_CONFIG=${FULL_CONFIG}" > "${GITLAB_ENV_PATH}/gitlab-runtime.env"
chmod 600 "${GITLAB_ENV_PATH}/gitlab-runtime.env"

### 5. Firewall Configuration
printf "%-8s%-80s\n" "[INFO]" "Firewall Configuration"
printf "%-8s%-80s\n" "[INFO]" "  > Configuring Firewall rules..."
FW_PORTS=()
[[ -n "$EXT_HTTP_PORT" ]] && FW_PORTS+=("$EXT_HTTP_PORT")
[[ -n "$EXT_HTTPS_PORT" ]] && FW_PORTS+=("$EXT_HTTPS_PORT")
FW_PORTS+=($(get_port_number "$GITLAB_PUBLISH_SSH" "22"))

for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "$SSH_PORT" ]]; then TYPE="ssh_port_t"; else TYPE="http_port_t"; fi
        semanage port -a -t $TYPE -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

### 6. Initial Container Deployment
printf "%-8s%-80s\n" "[INFO]" "Initial Container Deployment"
printf "%-8s%-80s\n" "[INFO]" "  > Initializing GitLab container..."
PORT_ARGS=()
[[ -n "$GITLAB_PUBLISH_HTTP" ]] && PORT_ARGS+=($(get_podman_port_arg "$GITLAB_PUBLISH_HTTP" "$GITLAB_INT_HTTP" "80"))
[[ -n "$GITLAB_PUBLISH_HTTPS" ]] && PORT_ARGS+=($(get_podman_port_arg "$GITLAB_PUBLISH_HTTPS" "$GITLAB_INT_HTTPS" "443"))
PORT_ARGS+=($(get_podman_port_arg "$GITLAB_PUBLISH_SSH" "$GITLAB_INT_SSH" "22"))

ERROR_VOL_ARGS=()
if [[ -d "$GITLAB_CUSTOM_ERR_PATH" ]]; then
    for CODE in "${ERR_CODES[@]}"; do
        if [[ -f "${GITLAB_CUSTOM_ERR_PATH}/${CODE}.html" ]]; then
            ERROR_VOL_ARGS+=("--volume" "${GITLAB_CUSTOM_ERR_PATH}/${CODE}.html:/opt/gitlab/embedded/service/gitlab-rails/public/${CODE}.html:ro,Z")
        fi
    done
fi

CMD_GITLAB=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$GITLAB_CONTAINER_NAME"
    "--hostname" "$GITLAB_HOST_NAME"
    "--shm-size" "256m"
    "--env-file" "${GITLAB_ENV_PATH}/gitlab-runtime.env"
    "--volume" "${LOCAL_CONFIG_PATH}:/etc/gitlab:Z"
    "--volume" "${LOCAL_SSL_PATH}:/etc/gitlab/ssl:Z"
    "--volume" "${REAL_LOG_PATH}:/var/log/gitlab:Z"
    "--volume" "${REAL_DATA_PATH}:/var/opt/gitlab:Z"
)
if [[ -n "${GITLAB_RES:-}" ]]; then
    CMD_GITLAB+=($GITLAB_RES)
fi
if [[ -n "${ERROR_VOL_ARGS[*]}" ]]; then
    CMD_GITLAB+=("${ERROR_VOL_ARGS[@]}")
fi
if [[ -n "${PORT_ARGS[*]}" ]]; then
    CMD_GITLAB+=("${PORT_ARGS[@]}")
fi
CMD_GITLAB+=("$GITLAB_IMAGE")

CMD_GITLAB_STR="${CMD_GITLAB[*]}"

printf "%-8s%-80s\n" "[INFO]" "  > Executing: $GITLAB_CONTAINER_NAME"
printf "%-8s%-80s\n" "[INFO]" "    >  $CMD_GITLAB_STR" # Debug
"${CMD_GITLAB[@]}"
wait_for_container "$GITLAB_CONTAINER_NAME"

### 7. Systemd Integration
printf "%-8s%-80s\n" "[INFO]" "Systemd Integration"
printf "%-8s%-80s\n" "[INFO]" "  > Generating Systemd unit files..."

cd /etc/systemd/system
podman generate systemd --new --files --name "$GITLAB_CONTAINER_NAME" >/dev/null
systemctl daemon-reload
systemctl enable "container-${GITLAB_CONTAINER_NAME}"

printf "%-8s%-80s\n" "[INFO]" "Helper Script Generation"
printf "%-8s%-80s\n" "[INFO]" "  > Creating Start Script..."
START_SCRIPT="${BASE_HOME}/start-gitlab.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
echo "Starting GitLab..."
systemctl start container-${GITLAB_CONTAINER_NAME}
echo "Done."
EOF
chmod 700 "$START_SCRIPT"

printf "%-8s%-80s\n" "[INFO]" "  > Creating Stop Script..."
STOP_SCRIPT="${BASE_HOME}/stop-gitlab.sh"
cat <<EOF > "$STOP_SCRIPT"
#!/bin/bash
echo "Stopping GitLab..."
systemctl stop container-${GITLAB_CONTAINER_NAME}
echo "Done."
EOF
chmod 700 "$STOP_SCRIPT"

printf "%-8s%-80s\n" "[INFO]" "Service Handover (Restart)"
printf "%-8s%-80s\n" "[INFO]" "  > Transitioning to Systemd management..."

stop_and_remove_container "$GITLAB_CONTAINER_NAME"

printf "%-8s%-80s\n" "[INFO]" "  > Starting GitLab via Systemd..."
systemctl start container-${GITLAB_CONTAINER_NAME}
wait_for_container "$GITLAB_CONTAINER_NAME"

### 8. Display Info
ROOT_PASS_FILE="${LOCAL_CONFIG_PATH}/initial_root_password"
printf "%-8s%-80s\n" "[INFO]" "----------------------------------------------------------------"
printf "%-8s%-80s\n" "[INFO]" " [SUCCESS] Installation Complete"
printf "%-8s%-80s\n" "[INFO]" "----------------------------------------------------------------"
if [[ "$OP_MODE" != "2" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "  Initial Root Password File: $ROOT_PASS_FILE"
    if [[ -f "$ROOT_PASS_FILE" ]]; then
        cat "$ROOT_PASS_FILE"
    fi
fi
echo ""