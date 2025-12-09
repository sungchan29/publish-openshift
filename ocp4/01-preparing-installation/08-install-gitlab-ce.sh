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

### 3. Data Directory
GITLAB_REAL_DATA_DIR="/data/gitlab-data"

### 4. Port Settings
GITLAB_PUBLISH_HTTP=""
GITLAB_PUBLISH_HTTPS=""
GITLAB_PUBLISH_SSH=""

######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### ==============================================================================
### 1. Port Configuration
### ==============================================================================

### Default values
GITLAB_PUBLISH_HTTP="${GITLAB_PUBLISH_HTTP:-7080}"
GITLAB_PUBLISH_HTTPS="${GITLAB_PUBLISH_HTTPS:-7443}"
GITLAB_PUBLISH_SSH="${GITLAB_PUBLISH_SSH:-2222}"

### ==============================================================================
### 2. Certificate Resolution Logic
### ==============================================================================

echo "Resolving certificate paths..."

if [[ -n "$GITLAB_CUSTOM_CERT" ]]; then
    GITLAB_CERT="$GITLAB_CUSTOM_CERT"
    echo "  > Using custom certificate path: $GITLAB_CERT"
else
    GITLAB_CERT="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.crt"
    echo "  > Using default certificate path: $GITLAB_CERT"
fi

if [[ -n "$GITLAB_CUSTOM_KEY" ]]; then
    GITLAB_KEY="$GITLAB_CUSTOM_KEY"
    echo "  > Using custom key path: $GITLAB_KEY"
else
    GITLAB_KEY="${CERT_BASE_DIR}/domain_certs/${GITLAB_HOST_NAME}.key"
    echo "  > Using default key path: $GITLAB_KEY"
fi

if [[ ! -f "$GITLAB_CERT" ]]; then
    echo "Error: Certificate file not found at: $GITLAB_CERT"
    exit 1
fi
if [[ ! -f "$GITLAB_KEY" ]]; then
    echo "Error: Key file not found at: $GITLAB_KEY"
    exit 1
fi

### ==============================================================================
### Helper Function: Parse Ports and Build Arguments
### ==============================================================================

get_port_number() {
    local input=$1
    echo "${input##*:}"
}

PODMAN_PORT_ARGS=()
FIREWALL_PORTS=()
OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}"
OMNIBUS_SHELL_SSH_PORT="22"

### --- Process HTTP Port ---
if [[ -n "$GITLAB_PUBLISH_HTTP" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_HTTP")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_HTTP}:80")
    FIREWALL_PORTS+=("$P_NUM")
fi

### --- Process HTTPS Port ---
if [[ -n "$GITLAB_PUBLISH_HTTPS" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_HTTPS")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_HTTPS}:443")
    FIREWALL_PORTS+=("$P_NUM")
    if [[ "$P_NUM" != "443" ]]; then
        OMNIBUS_EXTERNAL_URL="https://${GITLAB_HOST_NAME}:${P_NUM}"
    fi
fi

### --- Process SSH Port ---
if [[ -n "$GITLAB_PUBLISH_SSH" ]]; then
    P_NUM=$(get_port_number "$GITLAB_PUBLISH_SSH")
    PODMAN_PORT_ARGS+=("-p" "${GITLAB_PUBLISH_SSH}:22")
    FIREWALL_PORTS+=("$P_NUM")
    OMNIBUS_SHELL_SSH_PORT="$P_NUM"
fi

### ==============================================================================
### 3. Preparation (Cleanup)
### ==============================================================================

if [[ ! -d "$GITLAB_BASE_HOME" ]]; then
    mkdir -p "$GITLAB_BASE_HOME"
fi

### ==============================================================================
### 4. Directory Setup
### ==============================================================================

echo ""
echo "Configuring Directories..."

mkdir -p "${GITLAB_BASE_HOME}/config"
mkdir -p "${GITLAB_BASE_HOME}/ssl"
echo "  - Config/SSL located at: $GITLAB_BASE_HOME"

LINK_DATA_PATH="${GITLAB_BASE_HOME}/data"
LINK_LOG_PATH="${GITLAB_BASE_HOME}/log"

### Determine Real Physical Paths & Create Links
if [[ -n "$GITLAB_REAL_DATA_DIR" ]] && [[ "$GITLAB_REAL_DATA_DIR" != "$GITLAB_BASE_HOME" ]]; then
    REAL_DATA_PATH="${GITLAB_REAL_DATA_DIR}/data"
    REAL_LOG_PATH="${GITLAB_REAL_DATA_DIR}/log"
    echo "  - Using custom storage at: $GITLAB_REAL_DATA_DIR"

    mkdir -p "$REAL_DATA_PATH"
    mkdir -p "$REAL_LOG_PATH"

    echo "  - Updating symlinks in ${GITLAB_BASE_HOME}..."

    if [[ -d "$LINK_DATA_PATH" ]] && [[ ! -L "$LINK_DATA_PATH" ]]; then
        echo "    [Warning] Removing existing directory '$LINK_DATA_PATH' to replace with symlink."
        rm -rf "$LINK_DATA_PATH"
    fi
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"

    if [[ -d "$LINK_LOG_PATH" ]] && [[ ! -L "$LINK_LOG_PATH" ]]; then
        echo "    [Warning] Removing existing directory '$LINK_LOG_PATH' to replace with symlink."
        rm -rf "$LINK_LOG_PATH"
    fi
    ln -snf "$REAL_LOG_PATH" "$LINK_LOG_PATH"
else
    REAL_DATA_PATH="${GITLAB_BASE_HOME}/data"
    REAL_LOG_PATH="${GITLAB_BASE_HOME}/log"
    echo "  - Using standard storage at: $GITLAB_BASE_HOME"

    mkdir -p "$REAL_DATA_PATH"
    mkdir -p "$REAL_LOG_PATH"
fi

echo "    > Data Path: $(ls -ld "$LINK_DATA_PATH")"
echo "    > Log Path:  $(ls -ld "$LINK_LOG_PATH")"

### ==============================================================================
### 5. Install Certificates
### ==============================================================================

echo "Installing certificates..."
TARGET_CRT="${GITLAB_BASE_HOME}/ssl/${GITLAB_HOST_NAME}.crt"
TARGET_KEY="${GITLAB_BASE_HOME}/ssl/${GITLAB_HOST_NAME}.key"

cp "$GITLAB_CERT" "$TARGET_CRT"
cp "$GITLAB_KEY"  "$TARGET_KEY"

chmod 644 "$TARGET_CRT"
chmod 600 "$TARGET_KEY"

### ==============================================================================
### 6. Construct Omnibus Configuration
### ==============================================================================

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
### 7. Run GitLab Container
### ==============================================================================

echo ""
echo "Constructing GitLab container command..."

### Clean up existing container if it exists
if podman ps -a --format "{{.Names}}" | grep -q "^${GITLAB_CONTAINER_NAME}$"; then
    echo "  > Found existing container '${GITLAB_CONTAINER_NAME}'. Removing it..."
    podman rm -f "$GITLAB_CONTAINER_NAME"
fi

### Build the command array
PODMAN_ARGS=(podman run -d)
PODMAN_ARGS+=(--hostname "$GITLAB_HOST_NAME")
PODMAN_ARGS+=(--env GITLAB_OMNIBUS_CONFIG="$GITLAB_ENV_CONFIG")
PODMAN_ARGS+=("${PODMAN_PORT_ARGS[@]}")
PODMAN_ARGS+=(--restart always)
PODMAN_ARGS+=(--name "$GITLAB_CONTAINER_NAME")
PODMAN_ARGS+=(--volume "${GITLAB_BASE_HOME}/config:/etc/gitlab:Z")
PODMAN_ARGS+=(--volume "${GITLAB_BASE_HOME}/ssl:/etc/gitlab/ssl:Z")
PODMAN_ARGS+=(--volume "${REAL_LOG_PATH}:/var/log/gitlab:Z")
PODMAN_ARGS+=(--volume "${REAL_DATA_PATH}:/var/opt/gitlab:Z")
PODMAN_ARGS+=(--shm-size 256m)
PODMAN_ARGS+=("$GITLAB_IMAGE")

FINAL_CMD_STRING=$(printf "%q " "${PODMAN_ARGS[@]}")

### Print the command for verification
echo "----------------------------------------------------------------"
echo "Command to be executed (Safe String):"
echo ""
echo "$FINAL_CMD_STRING"
echo ""
echo "----------------------------------------------------------------"

### Execute the command
eval "$FINAL_CMD_STRING"

echo ""
echo "GitLab container started."
echo "----------------------------------------------------------------"
echo "[Verification] Actual command executed by Podman:"
echo ""
podman inspect "$GITLAB_CONTAINER_NAME" --format '{{range .Config.CreateCommand}}{{.}} {{end}}'
echo ""
echo "----------------------------------------------------------------"
echo ""
echo "Wait for initialization (2-5 mins)."
echo "Root password file: ${GITLAB_BASE_HOME}/config/initial_root_password"

### ==============================================================================
### 8. Configure Firewall and SELinux
### ==============================================================================

echo ""
echo "Configuring SELinux and Firewall..."

for PORT in "${FIREWALL_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        echo "Opening port $PORT/tcp..."
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