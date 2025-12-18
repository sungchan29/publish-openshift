#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
QUAY_HOST_NAME="quay.cloudpang.lan"
QUAY_BASE_HOME="/opt/quay"

### 2. Certificate Configuration
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
QUAY_CUSTOM_CERT=""   ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.crt
QUAY_CUSTOM_KEY=""    ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.key

### 3. Images (Red Hat Registry)
QUAY_IMAGE="registry.redhat.io/quay/quay-rhel8:v3.15.2"
PG_IMAGE="registry.redhat.io/rhel8/postgresql-16"
REDIS_IMAGE="registry.redhat.io/rhel8/redis-6"

### 4. Container Names
QUAY_CONTAINER_NAME="quay"
PG_CONTAINER_NAME="postgresql-quay"
REDIS_CONTAINER_NAME="redis-quay"

### 5. Credentials
PG_USER="quay"
PG_PASSWORD="redhat1!"
PG_DB_NAME="quay"
PG_ADMIN_PASSWORD="redhat1!"
REDIS_PASSWORD="redhat1!"

### 6. Data Directory (For Data and Logs only)
### If this path differs from QUAY_BASE_HOME, symlinks will be created.
QUAY_REAL_DATA_DIR="/data/quay"

### 7. Port Settings
### - Leave EMPTY to disable (e.g., HTTP).
### - Use "Port", "IP:Port" or "IP" (maps to Internal Port automatically).
QUAY_PUBLISH_HTTP=""
QUAY_PUBLISH_HTTPS="172.16.120.28:443"

DB_PUBLISH_PORT="172.16.120.28:5432"
REDIS_PUBLISH_PORT="172.16.120.28:6379"

### 8. Internal Container Ports (Managed via Variable)
QUAY_INT_HTTP="8080"
QUAY_INT_HTTPS="8443"
PG_INT_PORT="5432"
REDIS_INT_PORT="6379"

### 9. Resource Limits (Recommended for Production)
QUAY_CPU="4"
QUAY_MEM="8g"
PG_CPU="2"
PG_MEM="4g"
REDIS_CPU="1"
REDIS_MEM="2g"

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
### 2. Prerequisite Checks
### ==============================================================================

if [[ $EUID -ne 0 ]]; then echo "[ERROR] This script must be run as root."; exit 1; fi

echo "Checking Prerequisites..."
for cmd in podman setfacl uuidgen; do
    if ! command -v $cmd &> /dev/null; then echo "Installing $cmd..."; dnf install -y $cmd; fi
done

if grep -q "${QUAY_HOST_NAME}" /etc/hosts; then
    echo "  > [OK] Hostname check passed."
else
    echo "[ERROR] Hostname '${QUAY_HOST_NAME}' NOT found in /etc/hosts."; exit 1
fi

if [[ -z "$QUAY_PUBLISH_HTTP" ]] && [[ -z "$QUAY_PUBLISH_HTTPS" ]]; then
    echo "[ERROR] Invalid Configuration: At least one of HTTP or HTTPS must be set."
    exit 1
fi

### ==============================================================================
### 3. Certificate Resolution
### ==============================================================================

if [[ -n "$QUAY_PUBLISH_HTTPS" ]]; then
    echo "Resolving certificate paths..."
    if [[ -n "$QUAY_CUSTOM_CERT" ]]; then SOURCE_CERT="$QUAY_CUSTOM_CERT"; else SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.crt"; fi
    if [[ -n "$QUAY_CUSTOM_KEY" ]]; then SOURCE_KEY="$QUAY_CUSTOM_KEY"; else SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.key"; fi

    if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then
        echo "[ERROR] Certificate or Key file not found."; exit 1
    fi
    echo "  > Certificate found: $SOURCE_CERT"
fi

### ==============================================================================
### 4. Directory Setup & Initialization
### ==============================================================================

LOCAL_CONFIG_PATH="${QUAY_BASE_HOME}/config"
LINK_STORAGE_PATH="${QUAY_BASE_HOME}/storage"
LINK_PG_PATH="${QUAY_BASE_HOME}/postgres"
LINK_REDIS_PATH="${QUAY_BASE_HOME}/redis"

if [[ -n "$QUAY_REAL_DATA_DIR" ]] && [[ "$QUAY_REAL_DATA_DIR" != "$QUAY_BASE_HOME" ]]; then
    REAL_STORAGE_PATH="${QUAY_REAL_DATA_DIR}/storage"
    REAL_PG_PATH="${QUAY_REAL_DATA_DIR}/postgres"
    REAL_REDIS_PATH="${QUAY_REAL_DATA_DIR}/redis"
    IS_SPLIT_STORAGE=true
else
    REAL_STORAGE_PATH="${QUAY_BASE_HOME}/storage"
    REAL_PG_PATH="${QUAY_BASE_HOME}/postgres"
    REAL_REDIS_PATH="${QUAY_BASE_HOME}/redis"
    IS_SPLIT_STORAGE=false
fi

echo "Configuring Directories..."
DATA_EXISTS=false
if [[ -d "$REAL_STORAGE_PATH" ]] && [[ "$(ls -A "$REAL_STORAGE_PATH")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Quay data found!"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > Checking running containers..."
        RUNNING_CTRS=$(podman ps --format "{{.Names}}" | grep -E "^(${QUAY_CONTAINER_NAME}|${PG_CONTAINER_NAME}|${REDIS_CONTAINER_NAME})$")
        if [[ -n "$RUNNING_CTRS" ]]; then
            echo "[ERROR] Active containers detected: $RUNNING_CTRS"
            echo "        Please stop them manually using 'podman stop <name>'."
            exit 1
        fi

        podman rm -f "$QUAY_CONTAINER_NAME" "$PG_CONTAINER_NAME" "$REDIS_CONTAINER_NAME" 2>/dev/null || true

        echo "  > Cleaning Real Data..."
        rm -rf "${REAL_STORAGE_PATH:?}"/* "${REAL_PG_PATH:?}"/* "${REAL_REDIS_PATH:?}"/*
        echo "  > Cleaning Base Home..."
        if [[ -d "$QUAY_BASE_HOME" ]]; then rm -rf "${QUAY_BASE_HOME:?}"/*; fi
    else
        echo "  > [CANCEL] Installation aborted by user."
        exit 0
    fi
fi

mkdir -p "$LOCAL_CONFIG_PATH" "$REAL_STORAGE_PATH" "$REAL_PG_PATH" "$REAL_REDIS_PATH"
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    ln -snf "$REAL_STORAGE_PATH" "$LINK_STORAGE_PATH"
    ln -snf "$REAL_PG_PATH" "$LINK_PG_PATH"
    ln -snf "$REAL_REDIS_PATH" "$LINK_REDIS_PATH"
fi

### ==============================================================================
### 5. Install Certificates & Permissions
### ==============================================================================

if [[ -n "$QUAY_PUBLISH_HTTPS" ]]; then
    echo "Preparing SSL certificates..."
    TARGET_CRT="${LOCAL_CONFIG_PATH}/ssl.cert"
    TARGET_KEY="${LOCAL_CONFIG_PATH}/ssl.key"
    cp "$SOURCE_CERT" "$TARGET_CRT"; cp "$SOURCE_KEY"  "$TARGET_KEY"
    chmod 644 "$TARGET_CRT"; chmod 600 "$TARGET_KEY"
    setfacl -m u:1001:r "$TARGET_CRT" "$TARGET_KEY"
    echo "  > Certificates installed: $LOCAL_CONFIG_PATH"
fi

### ==============================================================================
### 6. Secrets
### ==============================================================================

ENV_FILE="${QUAY_BASE_HOME}/quay-secrets.env"
cat <<EOF > "$ENV_FILE"
POSTGRESQL_USER=${PG_USER}
POSTGRESQL_PASSWORD=${PG_PASSWORD}
POSTGRESQL_DATABASE=${PG_DB_NAME}
POSTGRESQL_ADMIN_PASSWORD=${PG_ADMIN_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
chmod 600 "$ENV_FILE"

### ==============================================================================
### 7. Component Deployment
### ==============================================================================

echo ""
echo "Deploying Components..."

### 7.1 PostgreSQL
setfacl -m u:26:-wx "$REAL_PG_PATH"
PG_PORT_ARG=$(get_podman_port_arg "$DB_PUBLISH_PORT" "$PG_INT_PORT" "false")

podman_pg_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$PG_CONTAINER_NAME"
    "--cpus" "${PG_CPU}" "--memory" "${PG_MEM}"
    "--env-file" "$ENV_FILE"
    $PG_PORT_ARG
    "--volume" "${REAL_PG_PATH}:/var/lib/pgsql/data:Z"
    "$PG_IMAGE"
)
podman rm -f "$PG_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "PostgreSQL Command:"
echo "${podman_pg_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_pg_cmd[@]}"

echo "  > Waiting for DB (10s)..."
sleep 10
pg_exec_cmd="podman exec -it $PG_CONTAINER_NAME /bin/bash -c \"psql -U $PG_USER -d $PG_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'\""
eval "$pg_exec_cmd"

### 7.2 Redis
REDIS_PORT_ARG=$(get_podman_port_arg "$REDIS_PUBLISH_PORT" "$REDIS_INT_PORT" "false")

podman_redis_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$REDIS_CONTAINER_NAME"
    "--cpus" "${REDIS_CPU}" "--memory" "${REDIS_MEM}"
    "--env-file" "$ENV_FILE"
    $REDIS_PORT_ARG
    "$REDIS_IMAGE"
)
podman rm -f "$REDIS_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Redis Command:"
echo "${podman_redis_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_redis_cmd[@]}"

### ==============================================================================
### 8. Quay Configuration
### ==============================================================================

echo "Generating Config..."
CONFIG_FILE="${LOCAL_CONFIG_PATH}/config.yaml"

DB_PORT=$(get_port_number "$DB_PUBLISH_PORT" "$PG_INT_PORT")
REDIS_PORT=$(get_port_number "$REDIS_PUBLISH_PORT" "$REDIS_INT_PORT")
SECRET_KEY=$(uuidgen)
DB_SECRET_KEY=$(uuidgen)

if [[ -n "$QUAY_PUBLISH_HTTPS" ]]; then SCHEME="https"; else SCHEME="http"; fi

cat <<EOF > "$CONFIG_FILE"
SERVER_HOSTNAME: ${QUAY_HOST_NAME}
SETUP_COMPLETE: true
SUPER_USERS:
  - quayadmin
PREFERRED_URL_SCHEME: ${SCHEME}
SECRET_KEY: ${SECRET_KEY}
DATABASE_SECRET_KEY: ${DB_SECRET_KEY}
DB_URI: postgresql://${PG_USER}:${PG_PASSWORD}@${QUAY_HOST_NAME}:${DB_PORT}/${PG_DB_NAME}
CREATE_NAMESPACE_ON_PUSH: true
BUILDLOGS_REDIS:
  host: ${QUAY_HOST_NAME}
  port: ${REDIS_PORT}
  password: ${REDIS_PASSWORD}
USER_EVENTS_REDIS:
  host: ${QUAY_HOST_NAME}
  port: ${REDIS_PORT}
  password: ${REDIS_PASSWORD}
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - LocalStorage
    - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
DISTRIBUTED_STORAGE_PREFERENCE:
    - default
FEATURE_MAILING: false
EOF

chmod 600 "$CONFIG_FILE"
setfacl -m u:1001:r "$CONFIG_FILE"

### ==============================================================================
### 9. Run Quay Container
### ==============================================================================

echo ""
echo "Constructing Quay command..."
setfacl -m u:1001:-wx "$REAL_STORAGE_PATH"

### Resolve Ports using Internal Variable
QUAY_HTTPS_ARG=$(get_podman_port_arg "$QUAY_PUBLISH_HTTPS" "$QUAY_INT_HTTPS" "false")
QUAY_HTTP_ARG=$(get_podman_port_arg "$QUAY_PUBLISH_HTTP" "$QUAY_INT_HTTP" "true")

podman_quay_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$QUAY_CONTAINER_NAME"
    "--cpus" "${QUAY_CPU}" "--memory" "${QUAY_MEM}"
    $QUAY_HTTPS_ARG
    $QUAY_HTTP_ARG
    "--volume" "${LOCAL_CONFIG_PATH}:/conf/stack:Z"
    "--volume" "${REAL_STORAGE_PATH}:/datastorage:Z"
    "$QUAY_IMAGE"
)

podman rm -f "$QUAY_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Quay Command:"
echo "${podman_quay_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_quay_cmd[@]}"

echo "  > Quay Started."

if [[ -n "$QUAY_PUBLISH_HTTPS" ]]; then
    DISP_PORT=$(get_port_number "$QUAY_PUBLISH_HTTPS" "$QUAY_INT_HTTPS")
    echo "    UI: https://${QUAY_HOST_NAME}:${DISP_PORT}"
else
    DISP_PORT=$(get_port_number "$QUAY_PUBLISH_HTTP" "$QUAY_INT_HTTP")
    echo "    UI: http://${QUAY_HOST_NAME}:${DISP_PORT}"
fi

### ==============================================================================
### 10. Configure Podman Trust (Only if HTTPS)
### ==============================================================================

if [[ -n "$QUAY_PUBLISH_HTTPS" ]]; then
    PODMAN_CERT_DIR="/etc/containers/certs.d/${QUAY_HOST_NAME}"
    if [[ ! -d "$PODMAN_CERT_DIR" ]]; then mkdir -p "$PODMAN_CERT_DIR"; fi
    cp "$SOURCE_CERT" "${PODMAN_CERT_DIR}/ca.crt"
    echo "  > Podman trust updated."
fi

### ==============================================================================
### 11. Firewall & Systemd
### ==============================================================================

echo ""
echo "Configuring Systemd & Firewall..."

FW_PORTS=(
    $(get_port_number "$QUAY_PUBLISH_HTTP" "")
    $(get_port_number "$QUAY_PUBLISH_HTTPS" "")
    $(get_port_number "$DB_PUBLISH_PORT" "")
    $(get_port_number "$REDIS_PUBLISH_PORT" "")
)

for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "5432" ]]; then TYPE="postgresql_port_t"; elif [[ "$PORT" == "6379" ]]; then TYPE="redis_port_t"; else TYPE="http_port_t"; fi
        semanage port -a -t $TYPE -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

cd /etc/systemd/system || exit
podman generate systemd --new --files --name "$PG_CONTAINER_NAME" >/dev/null
podman generate systemd --new --files --name "$REDIS_CONTAINER_NAME" >/dev/null
podman generate systemd --new --files --name "$QUAY_CONTAINER_NAME" >/dev/null

QUAY_SVC="container-${QUAY_CONTAINER_NAME}.service"
if [[ -f "$QUAY_SVC" ]] && ! grep -q "Requires=container-${PG_CONTAINER_NAME}.service" "$QUAY_SVC"; then
     sed -i "/^After=/ s/$/ container-${PG_CONTAINER_NAME}.service container-${REDIS_CONTAINER_NAME}.service/" "$QUAY_SVC"
     sed -i "/^After=/a Requires=container-${PG_CONTAINER_NAME}.service container-${REDIS_CONTAINER_NAME}.service" "$QUAY_SVC"
fi

systemctl daemon-reload
systemctl enable "container-${PG_CONTAINER_NAME}" "container-${REDIS_CONTAINER_NAME}" "container-${QUAY_CONTAINER_NAME}"

### ==============================================================================
### 12. Generate Start Scripts
### ==============================================================================

# 12.1 App Start Script
START_SCRIPT="${QUAY_BASE_HOME}/start-quay.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
ENV_FILE="${ENV_FILE}"
echo "Stopping containers..."
podman rm -f ${PG_CONTAINER_NAME} ${REDIS_CONTAINER_NAME} ${QUAY_CONTAINER_NAME} 2>/dev/null || true

echo "Starting DB & Redis..."
${podman_pg_cmd[*]}
${podman_redis_cmd[*]}

sleep 5
echo "Starting Quay..."
${podman_quay_cmd[*]}
echo "Done."
EOF
chmod 700 "$START_SCRIPT"

# 12.2 Config Editor Script
EDITOR_SCRIPT="${QUAY_BASE_HOME}/start-quay-config.sh"
EDITOR_PORT="8080"
EDITOR_CTR="quay-config"

cat <<EOF > "$EDITOR_SCRIPT"
#!/bin/bash
YELLOW='\033[1;33m'; NC='\033[0m'
echo -e "\${YELLOW}Starting Quay Config Editor...\${NC}"

if systemctl is-active --quiet "container-${QUAY_CONTAINER_NAME}"; then
    read -p "Quay is running. Stop it to run config editor? [y/N]: " confirm
    if [[ ! "\$confirm" =~ ^[Yy]\$ ]]; then exit 0; fi
    systemctl stop "container-${QUAY_CONTAINER_NAME}"
fi
podman rm -f "${QUAY_CONTAINER_NAME}" >/dev/null 2>&1

echo "URL: http://${QUAY_HOST_NAME}:${EDITOR_PORT} (User: quayadmin, Pass: secret)"
podman run --rm -it --name "${EDITOR_CTR}" -p ${EDITOR_PORT}:8080 -v ${LOCAL_CONFIG_PATH}:/conf/stack:Z ${QUAY_IMAGE} config secret
echo -e "\${YELLOW}Editor closed. Restart Quay with 'systemctl start container-${QUAY_CONTAINER_NAME}'\${NC}"
EOF
chmod 700 "$EDITOR_SCRIPT"

echo "  > Script created: $START_SCRIPT"
echo "----------------------------------------------------------------"
echo " [SUCCESS] Quay Installation Complete"
echo "----------------------------------------------------------------"
echo ""