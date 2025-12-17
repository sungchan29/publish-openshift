#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
GITLAB_HOST_NAME="gitlab.cloudpang.lan"
GITLAB_BASE_HOME="/opt/gitlab"

GITLAB_IMAGE="docker.io/gitlab/gitlab-ce:latest"
GITLAB_CONTAINER_NAME="gitlab"

### 2. Certificate Configuration (Flexible)
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
GITLAB_CUSTOM_CERT=""
GITLAB_CUSTOM_KEY=""

### 3. Data Directory (For Data and Logs only)
GITLAB_REAL_DATA_DIR="/data/gitlab"

### 4. Port Settings
GITLAB_PUBLISH_HTTP="172.16.120.28:7080"
GITLAB_PUBLISH_HTTPS="172.16.120.28:7443"
GITLAB_PUBLISH_SSH="2222"

### 5. Resource Limits
### GitLab Recommended: 4 Cores, 4GB+ RAM (8GB preferred for stability)
GITLAB_CPU="4"
GITLAB_MEM="8g"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Port Configuration
### ==============================================================================

GITLAB_PUBLISH_HTTP="${GITLAB_PUBLISH_HTTP:-7080}"
GITLAB_PUBLISH_HTTPS="${GITLAB_PUBLISH_HTTPS:-7443}"
GITLAB_PUBLISH_SSH="${GITLAB_PUBLISH_SSH:-2222}"

### ==============================================================================
### 2. Certificate Resolution Logic
### ==============================================================================

echo "Resolving certificate paths..."

if [[ -n "$GITLAB_CUSTOM_CERT" ]]; then
    GITLAB_CERT="$GITLAB_CUSTOM_CERT"
else
    GITLAB_CERT="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.crt"
fi

if [[ -n "$GITLAB_CUSTOM_KEY" ]]; then
    GITLAB_KEY="$GITLAB_CUSTOM_KEY"
else
    GITLAB_KEY="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.key"
fi

if [[ ! -f "$GITLAB_CERT" ]] || [[ ! -f "$GITLAB_KEY" ]]; then
    echo "[ERROR] Certificate or Key file not found."
    exit 1
fi

### ==============================================================================
### Helper: Parse Ports
### ==============================================================================

get_port_number() {
    local input=$1
    echo "${input##*:}"
}

PODMAN_PORT_ARGS=()
FIREWALL_PORTS=()
OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}"
OMNIBUS_SHELL_SSH_PORT="22"

### HTTP
if [[ -n "$GITLAB_PUBLISH_HTTP" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_HTTP")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_HTTP}:80")
    FIREWALL_PORTS+=("$P_NUM")
fi

### HTTPS
if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_HTTPS")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_HTTPS}:443")
    FIREWALL_PORTS+=("$P_NUM")
    if [[ "$P_NUM" != "443" ]]; then
        OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}:${P_NUM}"
    fi
fi

### SSH
if [[ -n "$GITLAB_PUBLISH_SSH" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_SSH")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_SSH}:22")
    FIREWALL_PORTS+=("$P_NUM")
    OMNIBUS_SHELL_SSH_PORT="$P_NUM"
fi

### ==============================================================================
### 3. Directory Setup & Interactive Initialization
### ==============================================================================

### Define Location Variables
### 1. Base Home Paths (Config & SSL)
LOCAL_CONFIG_PATH="${GITLAB_BASE_HOME}/config"
LOCAL_SSL_PATH="${GITLAB_BASE_HOME}/ssl"

### 2. Real Data Paths (Data & Logs)
if [[ -n "$GITLAB_REAL_DATA_DIR" ]] && [[ "$GITLAB_REAL_DATA_DIR" != "$GITLAB_BASE_HOME" ]]; then
    REAL_DATA_PATH="${GITLAB_REAL_DATA_DIR}/data"
    REAL_LOG_PATH="${GITLAB_REAL_DATA_DIR}/logs"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${GITLAB_BASE_HOME}/data"
    REAL_LOG_PATH="${GITLAB_BASE_HOME}/logs"
    IS_SPLIT_STORAGE=false
fi

echo ""
echo "Configuring Directories..."
echo "  [Base Home] Config Path : $LOCAL_CONFIG_PATH"
echo "  [Base Home] SSL Path    : $LOCAL_SSL_PATH"
echo "  [Real Data] Data Path   : $REAL_DATA_PATH"
echo "  [Real Data] Logs Path   : $REAL_LOG_PATH"

### [Interactive Initialization Check]
DATA_EXISTS=false
if [[ -d "$REAL_DATA_PATH" ]] && [[ "$(ls -A "$REAL_DATA_PATH")" ]]; then DATA_EXISTS=true; fi
if [[ -d "$GITLAB_BASE_HOME" ]] && [[ "$(ls -A "$GITLAB_BASE_HOME")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing GitLab data found!"
    echo "=================================================================="
    echo " Locations detected:"
    echo "  - Data Storage : $GITLAB_REAL_DATA_DIR"
    echo "  - Base Home    : $GITLAB_BASE_HOME"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data, logs, config, and SSL)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        ### -----------------------------------------------------------
        ### [ADDED LOGIC] Check if containers are running and EXIT
        ### -----------------------------------------------------------
        echo "  > [Check] Verifying container status..."

        ### Check running containers matching our names
        RUNNING_CTRS=$(podman ps --format "{{.Names}}" | grep -E "^(${GITLAB_CONTAINER_NAME})$")

        if [[ -n "$RUNNING_CTRS" ]]; then
            echo ""
            echo "=================================================================="
            echo " [ERROR] Active containers detected!"
            echo "=================================================================="
            echo " Initialization cannot proceed while the following containers are running:"
            echo ""
            echo "$RUNNING_CTRS"
            echo ""
            echo " [ACTION REQUIRED]"
            echo " Please stop them manually using 'podman stop <container_name>'."
            echo " Script aborted to prevent data corruption."
            echo "=================================================================="
            exit 1
        fi

        echo "  > [Step 1] Cleaning Real Data & Logs..."

        ### Remove STOPPED containers (Safe cleanup)
        podman rm "$GITLAB_CONTAINER_NAME" 2>/dev/null || true

        ### Clean external data first
        if [[ -d "$REAL_DATA_PATH" ]]; then rm -rf "${REAL_DATA_PATH:?}"/*; fi
        if [[ -d "$REAL_LOG_PATH" ]]; then rm -rf "${REAL_LOG_PATH:?}"/*; fi

        echo "  > [Step 2] Cleaning Base Home (Config, SSL, Symlinks)..."
        ### Clean everything in Base Home (This removes config, ssl, and old symlinks)
        if [[ -d "$GITLAB_BASE_HOME" ]]; then
             rm -rf "${GITLAB_BASE_HOME:?}"/*
        fi

        echo "  > [Check] All directories initialized."
    else
        ### Exit if user says No
        echo ""
        echo "  > [CANCEL] Installation aborted by user."
        echo "             Existing data was preserved. Exiting script."
        echo "=================================================================="
        exit 0
    fi
fi

### Create Directories (Re-create structure after wipe)
mkdir -p "$LOCAL_CONFIG_PATH"
mkdir -p "$LOCAL_SSL_PATH"
mkdir -p "$REAL_DATA_PATH"
mkdir -p "$REAL_LOG_PATH"

### Symbolic Link Logic (Optional: Links Real path to Base Home for visibility)
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    LINK_DATA_PATH="${GITLAB_BASE_HOME}/data"
    LINK_LOG_PATH="${GITLAB_BASE_HOME}/logs"

    ### Link Data
    if [[ -d "$LINK_DATA_PATH" ]] && [[ ! -L "$LINK_DATA_PATH" ]]; then rm -rf "$LINK_DATA_PATH"; fi
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"

    ### Link Logs
    if [[ -d "$LINK_LOG_PATH" ]] && [[ ! -L "$LINK_LOG_PATH" ]]; then rm -rf "$LINK_LOG_PATH"; fi
    ln -snf "$REAL_LOG_PATH" "$LINK_LOG_PATH"
fi

### ==============================================================================
### 4. Install Certificates
### ==============================================================================

echo ""
echo "Preparing SSL certificates..."

TARGET_CRT="${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.crt"
TARGET_KEY="${LOCAL_SSL_PATH}/${GITLAB_HOST_NAME}.key"

cp "$GITLAB_CERT" "$TARGET_CRT"
cp "$GITLAB_KEY"  "$TARGET_KEY"

chmod 644 "$TARGET_CRT"
chmod 600 "$TARGET_KEY"

echo "  > Certificates copied to: $LOCAL_SSL_PATH"

### ==============================================================================
### 5. Construct GitLab Configuration
### ==============================================================================

### Note: In the config below, paths refer to locations INSIDE the container
RAW_CONFIG="
external_url '${OMNIBUS_EXTERNAL_URL}';
nginx['redirect_http_to_https'] = true;
nginx['listen_port'] = 443;
nginx['ssl_certificate'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.crt';
nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/${GITLAB_HOST_NAME}.key';
gitlab_rails['gitlab_shell_ssh_port'] = ${OMNIBUS_SHELL_SSH_PORT};
"

GITLAB_ENV_CONFIG=$(echo "$RAW_CONFIG" | tr '\n' ' ')

### ==============================================================================
### 6. Run GitLab Container
### ==============================================================================

echo ""
echo "Constructing GitLab container command..."

### Constructing command using Single Bash Array Block
podman_cmd=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$GITLAB_CONTAINER_NAME"
    "--hostname" "$GITLAB_HOST_NAME"
    "--shm-size" "256m"

    ### Resource Limits
    "--cpus" "${GITLAB_CPU}"
    "--memory" "${GITLAB_MEM}"

    ### Environment Variables
    "--env" "GITLAB_OMNIBUS_CONFIG=${GITLAB_ENV_CONFIG}"

    ### Volume Arguments (4 Distinct Volumes)
    "--volume" "${LOCAL_CONFIG_PATH}:/etc/gitlab:Z"
    "--volume" "${LOCAL_SSL_PATH}:/etc/gitlab/ssl:Z"
    "--volume" "${REAL_LOG_PATH}:/var/log/gitlab:Z"
    "--volume" "${REAL_DATA_PATH}:/var/opt/gitlab:Z"

    ### Port Arguments (Expanded from array)
    "${PODMAN_PORT_ARGS[@]}"

    ### Image Name
    "$GITLAB_IMAGE"
)

# Remove existing container (Force remove to ensure clean slate for RUN)
podman rm -f "$GITLAB_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Command to be executed:"
echo "${podman_cmd[*]}"
echo "----------------------------------------------------------------"

### Execute the array
"${podman_cmd[@]}"

echo ""
echo "GitLab container started."
echo "Wait for initialization (2-5 mins)."
echo "Initial root password file: ${LOCAL_CONFIG_PATH}/initial_root_password"

### ==============================================================================
### 7. Firewall
### ==============================================================================

echo ""
echo "Configuring Firewall..."
for PORT in "${FIREWALL_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "$OMNIBUS_SHELL_SSH_PORT" ]]; then
             semanage port -a -t ssh_port_t -p tcp ${PORT} 2>/dev/null || true
        else
             semanage port -a -t http_port_t -p tcp ${PORT} 2>/dev/null || true
        fi
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp
    fi
done
firewall-cmd --reload
echo ""

### ==============================================================================
### 8. Generate 'start-gitlab.sh' (Standalone Startup Script)
### ==============================================================================

echo "Generating standalone startup script: start-gitlab.sh ..."

START_SCRIPT="${GITLAB_BASE_HOME}/start-gitlab.sh"

### We inject variables directly into the script for a standalone execution.
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
# ============================================================================
# GitLab Standalone Startup Script
# Generated by install script on $(date)
# ============================================================================

echo "Stopping and removing existing container..."
podman rm -f ${GITLAB_CONTAINER_NAME} 2>/dev/null || true

echo "Starting GitLab..."
podman run -d \\
    --restart always \\
    --name ${GITLAB_CONTAINER_NAME} \\
    --hostname ${GITLAB_HOST_NAME} \\
    --shm-size 256m \\
    --cpus ${GITLAB_CPU} \\
    --memory ${GITLAB_MEM} \\
    --env "GITLAB_OMNIBUS_CONFIG=${GITLAB_ENV_CONFIG}" \\
    --volume ${LOCAL_CONFIG_PATH}:/etc/gitlab:Z \\
    --volume ${LOCAL_SSL_PATH}:/etc/gitlab/ssl:Z \\
    --volume ${REAL_LOG_PATH}:/var/log/gitlab:Z \\
    --volume ${REAL_DATA_PATH}:/var/opt/gitlab:Z \\
    ${PODMAN_PORT_ARGS[*]} \\
    ${GITLAB_IMAGE}

echo "GitLab started."
EOF

chmod +x "$START_SCRIPT"
echo "  > Script created at: $START_SCRIPT"
echo "  > You can use this script to manually restart GitLab later."

### ==============================================================================
### 9. Register as RHEL 9 Systemd Service (Auto-Start)
### ==============================================================================

echo ""
echo "Configuring Systemd for Auto-Start..."

SYSTEMD_DIR="/etc/systemd/system"

### Generate Unit Files
cd "$SYSTEMD_DIR" || exit

echo "  > Generating Service: container-${GITLAB_CONTAINER_NAME}.service"
### Generate service file (restart policy handled by systemd, container removal handled by service wrapper)
podman generate systemd --new --files --name "$GITLAB_CONTAINER_NAME" >/dev/null

### Reload and Enable
systemctl daemon-reload
systemctl enable "container-${GITLAB_CONTAINER_NAME}"

echo ""
echo "----------------------------------------------------------------"
echo " [SUCCESS] Installation & Service Registration Complete"
echo "----------------------------------------------------------------"
echo " 1. Manual Start Script : $START_SCRIPT"
echo " 2. Systemd Services    : Enabled (Starts on boot)"
echo ""
echo " IMPORTANT: Currently, GitLab is running via 'podman run'."
echo " To switch to Systemd management immediately, run:"
echo "   podman stop ${GITLAB_CONTAINER_NAME}"
echo "   systemctl start container-${GITLAB_CONTAINER_NAME}"
echo "----------------------------------------------------------------"
echo ""