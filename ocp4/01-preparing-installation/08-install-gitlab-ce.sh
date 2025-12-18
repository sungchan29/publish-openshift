#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
GITLAB_HOST_NAME="gitlab.cloudpang.lan"
GITLAB_BASE_HOME="/opt/gitlab"

GITLAB_IMAGE="docker.io/gitlab/gitlab-ce:latest"
GITLAB_CONTAINER_NAME="gitlab"

### 2. Certificate Configuration
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
GITLAB_CUSTOM_CERT="" ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.crt
GITLAB_CUSTOM_KEY=""  ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.key

### 3. Data Directory
GITLAB_REAL_DATA_DIR="/data/gitlab"

### 4. Port Settings
### - Leave EMPTY to disable.
### - Use "Port", "IP:Port" or "IP" (maps to Internal Port automatically).
GITLAB_PUBLISH_HTTP=""
GITLAB_PUBLISH_HTTPS="172.16.120.28:7443"
GITLAB_PUBLISH_SSH="172.16.120.28:2222"

### 5. Internal Container Ports
GITLAB_INT_HTTP="80"
GITLAB_INT_HTTPS="443"
GITLAB_INT_SSH="22"

### 6. Resource Limits
GITLAB_CPU="4"
GITLAB_MEM="8g"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Helper: Port Management
### ==============================================================================

get_port_number() {
    local input=$1
    local default=$2
    if [[ -z "$input" ]]; then
        echo "$default"
    elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$default"
    else
        echo "${input##*:}"
    fi
}

get_podman_port_arg() {
    local config_val=$1
    local internal_port=$2
    local is_optional=$3

    if [[ -z "$config_val" ]]; then
        if [[ "$is_optional" == "true" ]]; then
            echo ""
        else
            echo "-p ${internal_port}:${internal_port}"
        fi
    elif [[ "$config_val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "-p ${config_val}:${internal_port}:${internal_port}"
    else
        echo "-p ${config_val}:${internal_port}"
    fi
}

### ==============================================================================
### 2. Validation
### ==============================================================================

if [[ $EUID -ne 0 ]]; then echo "[ERROR] Run as root."; exit 1; fi

if [[ -z "$GITLAB_PUBLISH_HTTP" ]] && [[ -z "$GITLAB_PUBLISH_HTTPS" ]]; then
    echo "[ERROR] Invalid Configuration: At least one of HTTP or HTTPS must be set."
    exit 1
fi

### Conflict Check: HTTP Redirect Limitation
if [[ -n "$GITLAB_PUBLISH_HTTP" ]]; then
    HTTPS_PORT_CHECK=$(get_port_number "$GITLAB_PUBLISH_HTTPS" "443")

    if [[ "$HTTPS_PORT_CHECK" != "443" ]]; then
        echo ""
        echo "=================================================================="
        echo " [ERROR] Invalid Configuration for HTTP Redirect"
        echo "=================================================================="
        echo " You have enabled HTTP (GITLAB_PUBLISH_HTTP)."
        echo " However, your HTTPS port is set to '$HTTPS_PORT_CHECK' (not 443)."
        echo ""
        echo " GitLab Nginx cannot handle HTTP->HTTPS redirection correctly"
        echo " when HTTPS is running on a non-standard port."
        echo ""
        echo " [SOLUTION]"
        echo " 1. Change GITLAB_PUBLISH_HTTPS to use port 443."
        echo " 2. OR Disable GITLAB_PUBLISH_HTTP (leave it empty)."
        echo "=================================================================="
        echo ""
        exit 1
    fi
fi

### ==============================================================================
### 3. Certificate Resolution
### ==============================================================================

if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    echo "Resolving certificate paths..."
    if [[ -n "$GITLAB_CUSTOM_CERT" ]]; then SOURCE_CERT="$GITLAB_CUSTOM_CERT"; else SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.crt"; fi
    if [[ -n "$GITLAB_CUSTOM_KEY" ]]; then SOURCE_KEY="$GITLAB_CUSTOM_KEY"; else SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.key"; fi

    if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then
        echo "[ERROR] Certificate or Key file not found."; exit 1
    fi
fi

### ==============================================================================
### 4. Directory Setup
### ==============================================================================

LOCAL_CONFIG_PATH="${GITLAB_BASE_HOME}/config"
LOCAL_SSL_PATH="${GITLAB_BASE_HOME}/ssl"

if [[ -n "$GITLAB_REAL_DATA_DIR" ]] && [[ "$GITLAB_REAL_DATA_DIR" != "$GITLAB_BASE_HOME" ]]; then
    REAL_DATA_PATH="${GITLAB_REAL_DATA_DIR}/data"
    REAL_LOG_PATH="${GITLAB_REAL_DATA_DIR}/logs"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${GITLAB_BASE_HOME}/data"
    REAL_LOG_PATH="${GITLAB_BASE_HOME}/logs"
    IS_SPLIT_STORAGE=false
fi

echo "Configuring Directories..."
DATA_EXISTS=false
if [[ -d "$REAL_DATA_PATH" ]] && [[ "$(ls -A "$REAL_DATA_PATH")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing GitLab data found!"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > Checking running containers..."
        if podman ps --format "{{.Names}}" | grep -q "^${GITLAB_CONTAINER_NAME}$"; then
            echo "[ERROR] Container is running. Stop it first."; echo ""; exit 1
        fi
        podman rm -f "$GITLAB_CONTAINER_NAME" 2>/dev/null || true

        echo "  > Cleaning Real Data..."
        rm -rf "${REAL_DATA_PATH:?}"/* "${REAL_LOG_PATH:?}"/*
        echo "  > Cleaning Base Home..."
        if [[ -d "$GITLAB_BASE_HOME" ]]; then rm -rf "${GITLAB_BASE_HOME:?}"/*; fi
    else
        echo "  > Aborted by user."; exit 0
    fi
fi

mkdir -p "$LOCAL_CONFIG_PATH" "$LOCAL_SSL_PATH" "$REAL_DATA_PATH" "$REAL_LOG_PATH"
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    LINK_DATA_PATH="${GITLAB_BASE_HOME}/data"; if [[ -d "$LINK_DATA_PATH" ]]; then rm -rf "$LINK_DATA_PATH"; fi; ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
    LINK_LOG_PATH="${GITLAB_BASE_HOME}/logs"; if [[ -d "$LINK_LOG_PATH" ]]; then rm -rf "$LINK_LOG_PATH"; fi; ln -snf "$REAL_LOG_PATH" "$LINK_LOG_PATH"
fi

### ==============================================================================
### 5. Install Certificates
### ==============================================================================

if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    echo "Preparing SSL certificates..."
    TARGET_CRT="${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.crt"
    TARGET_KEY="${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.key"
    cp "$SOURCE_CERT" "$TARGET_CRT"; cp "$SOURCE_KEY" "$TARGET_KEY"
    chmod 644 "$TARGET_CRT"; chmod 600 "$TARGET_KEY"
    echo "  > Certificates copied: $LOCAL_SSL_PATH"
fi

### ==============================================================================
### 6. Construct Configuration
### ==============================================================================

echo "Generating Omnibus Configuration..."

if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    ### HTTPS Config Logic
    EXT_HTTPS_PORT=$(get_port_number "$GITLAB_PUBLISH_HTTPS" "$GITLAB_INT_HTTPS")

    if [[ "$EXT_HTTPS_PORT" == "443" ]]; then
        ### Standard Port (443): Enable Redirect if HTTP published
        OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}"
        NGINX_REDIRECT="true"
    else
        ### Non-Standard Port: Disable Redirect to avoid conflict
        OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}:${EXT_HTTPS_PORT}"
        NGINX_REDIRECT="false"
    fi

    NGINX_CONFIG="
    nginx['redirect_http_to_https'] = ${NGINX_REDIRECT};
    nginx['listen_port'] = ${GITLAB_INT_HTTPS};
    nginx['listen_https'] = true;
    nginx['ssl_certificate'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.crt';
    nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.key';
    "
else
    ### HTTP Config Logic
    EXT_HTTP_PORT=$(get_port_number "$GITLAB_PUBLISH_HTTP" "$GITLAB_INT_HTTP")

    if [[ "$EXT_HTTP_PORT" == "80" ]]; then
        OMNIBUS_EXTERNAL_URL="http://${GITLAB_HOST_NAME}"
    else
        OMNIBUS_EXTERNAL_URL="http://${GITLAB_HOST_NAME}:${EXT_HTTP_PORT}"
    fi

    NGINX_CONFIG="
    nginx['listen_port'] = ${GITLAB_INT_HTTP};
    nginx['listen_https'] = false;
    nginx['redirect_http_to_https'] = false;
    "
fi

SSH_PORT=$(get_port_number "$GITLAB_PUBLISH_SSH" "$GITLAB_INT_SSH")
RAW_CONFIG="external_url '${OMNIBUS_EXTERNAL_URL}'; gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}; ${NGINX_CONFIG}"
GITLAB_ENV_CONFIG=$(echo "$RAW_CONFIG" | tr '\n' ' ')

### ==============================================================================
### 7. Run Container
### ==============================================================================

echo "Constructing GitLab command..."

HTTP_ARG=$(get_podman_port_arg "$GITLAB_PUBLISH_HTTP" "$GITLAB_INT_HTTP" "true")
HTTPS_ARG=$(get_podman_port_arg "$GITLAB_PUBLISH_HTTPS" "$GITLAB_INT_HTTPS" "true")
SSH_ARG=$(get_podman_port_arg "$GITLAB_PUBLISH_SSH" "$GITLAB_INT_SSH" "true")

podman_gitlab_cmd=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$GITLAB_CONTAINER_NAME"
    "--hostname" "$GITLAB_HOST_NAME"
    "--shm-size" "256m"
    "--cpus" "${GITLAB_CPU}"
    "--memory" "${GITLAB_MEM}"
    "--env" "GITLAB_OMNIBUS_CONFIG=${GITLAB_ENV_CONFIG}"
    "--volume" "${LOCAL_CONFIG_PATH}:/etc/gitlab:Z"
    "--volume" "${LOCAL_SSL_PATH}:/etc/gitlab/ssl:Z"
    "--volume" "${REAL_LOG_PATH}:/var/log/gitlab:Z"
    "--volume" "${REAL_DATA_PATH}:/var/opt/gitlab:Z"
    $HTTP_ARG
    $HTTPS_ARG
    $SSH_ARG
    "$GITLAB_IMAGE"
)

podman rm -f "$GITLAB_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "GitLab Command:"
echo "${podman_gitlab_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_gitlab_cmd[@]}"

echo "  > GitLab started."

### ==============================================================================
### 8. Systemd & Firewall
### ==============================================================================

echo ""
echo "Configuring Systemd & Firewall..."

FW_PORTS=(
    $(get_port_number "$GITLAB_PUBLISH_HTTP" "")
    $(get_port_number "$GITLAB_PUBLISH_HTTPS" "")
    $(get_port_number "$GITLAB_PUBLISH_SSH" "")
)

for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "$SSH_PORT" ]]; then TYPE="ssh_port_t"; else TYPE="http_port_t"; fi
        semanage port -a -t $TYPE -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

cd /etc/systemd/system || exit
podman generate systemd --new --files --name "$GITLAB_CONTAINER_NAME" >/dev/null
systemctl daemon-reload
systemctl enable "container-${GITLAB_CONTAINER_NAME}"

### ==============================================================================
### 9. Generate Start Script
### ==============================================================================

START_SCRIPT="${GITLAB_BASE_HOME}/start-gitlab.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
echo "Stopping container..."
podman rm -f ${GITLAB_CONTAINER_NAME} 2>/dev/null || true

echo "Starting GitLab..."
${podman_gitlab_cmd[*]}

echo "GitLab started."
EOF
chmod 700 "$START_SCRIPT"

### ==============================================================================
### 10. Display Initial Password Information & Access Guide
### ==============================================================================

ROOT_PASS_FILE="${LOCAL_CONFIG_PATH}/initial_root_password"

echo ""
echo "----------------------------------------------------------------"
echo " [SUCCESS] GitLab Installation Complete"
echo "----------------------------------------------------------------"
echo " 1. Manual Start Script : $START_SCRIPT"
echo " 2. Systemd Service     : Enabled (container-${GITLAB_CONTAINER_NAME})"
echo ""

echo "=================================================================="
echo " [INFO] Initial Root Password"
echo "=================================================================="
echo " File Path : $ROOT_PASS_FILE"
echo ""

if [[ -f "$ROOT_PASS_FILE" ]]; then
    echo " Password Content:"
    echo " -----------------------------------------------------------"
    grep "Password:" "$ROOT_PASS_FILE"
    echo " -----------------------------------------------------------"
    echo " * Note: This file will be deleted automatically after 24h."
else
    echo " [NOTE] GitLab is currently initializing (takes 2-5 minutes)."
    echo "        The password file has not been generated yet."
    echo ""
    echo " To check later, run:"
    echo "   cat $ROOT_PASS_FILE"
    echo ""
    echo " Or follow the logs:"
    echo "   podman logs -f $GITLAB_CONTAINER_NAME"
fi
echo "=================================================================="
echo ""