#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
CLAIR_HOST_NAME="clair.cloudpang.lan"
CLAIR_BASE_HOME="/opt/clair-quay"

### [Integration] Root CA for Registry Trust
ROOT_CA_PATH="/root/ocp4/support-system/custom-certs/rootCA/rootCA.crt"

### 2. Images
CLAIR_IMAGE="registry.redhat.io/quay/clair-rhel8:v3.15.2"
PG_IMAGE="registry.redhat.io/rhel8/postgresql-16"

### 3. Container Names
CLAIR_CONTAINER_NAME="clair"
PG_CONTAINER_NAME="postgresql-clair"

### 4. Credentials
PG_USER="clair"
PG_PASSWORD="redhat1!"
PG_DB_NAME="clair"
PG_ADMIN_PASSWORD="redhat1!"

### 5. Data Directory
CLAIR_REAL_DATA_DIR="/data/clair"

### 6. Port Settings
### - Leave EMPTY to disable.
### - Use "Port", "IP:Port" or "IP" (maps to Internal Port automatically).
CLAIR_PUBLISH_HTTP="172.16.120.28:8081"
CLAIR_PUBLISH_INTRO="172.16.120.28:8088"
DB_PUBLISH_PORT="172.16.120.28:5433"

### 7. Internal Container Ports (Managed via Variable)
CLAIR_INT_HTTP="8081"
CLAIR_INT_INTRO="8088"
PG_INT_PORT="5432"

### 8. Resource Limits
CLAIR_CPU="4"
CLAIR_MEM="8g"
PG_CPU="2"
PG_MEM="4g"

### 9. Quay Integration (Pre-Shared Key)
CLAIR_PSK=""

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

if grep -q "${CLAIR_HOST_NAME}" /etc/hosts; then
    echo "  > [OK] Hostname check passed."
else
    echo "[ERROR] Hostname '${CLAIR_HOST_NAME}' NOT found in /etc/hosts."; exit 1
fi

if [[ ! -f "$ROOT_CA_PATH" ]]; then
    echo "[ERROR] Root CA file not found: $ROOT_CA_PATH"; exit 1
fi

if [[ -z "$CLAIR_PSK" ]]; then
    echo ""
    read -p " > Enter Clair PSK (from Quay Config): " CLAIR_PSK
    if [[ -z "$CLAIR_PSK" ]]; then echo "[ERROR] PSK required."; exit 1; fi
fi

### ==============================================================================
### 3. Directory Setup & Initialization
### ==============================================================================

LOCAL_CONFIG_PATH="${CLAIR_BASE_HOME}/config"
LINK_PG_PATH="${CLAIR_BASE_HOME}/postgres"

if [[ -n "$CLAIR_REAL_DATA_DIR" ]] && [[ "$CLAIR_REAL_DATA_DIR" != "$CLAIR_BASE_HOME" ]]; then
    REAL_PG_PATH="${CLAIR_REAL_DATA_DIR}/postgres"
    IS_SPLIT_STORAGE=true
else
    REAL_PG_PATH="${CLAIR_BASE_HOME}/postgres"
    IS_SPLIT_STORAGE=false
fi

echo "Configuring Directories..."
DATA_EXISTS=false
if [[ -d "$REAL_PG_PATH" ]] && [[ "$(ls -A "$REAL_PG_PATH")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Clair data found!"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > Checking containers..."
        if podman ps --format "{{.Names}}" | grep -E "^(${CLAIR_CONTAINER_NAME}|${PG_CONTAINER_NAME})$"; then
            echo "[ERROR] Containers running. Please stop them manually:"
            echo "        podman stop ${CLAIR_CONTAINER_NAME} ${PG_CONTAINER_NAME}"
            exit 1
        fi
        podman rm -f "$CLAIR_CONTAINER_NAME" "$PG_CONTAINER_NAME" 2>/dev/null || true

        echo "  > Cleaning Real Data..."
        rm -rf "${REAL_PG_PATH:?}"/*
        echo "  > Cleaning Base Home..."
        if [[ -d "$CLAIR_BASE_HOME" ]]; then rm -rf "${CLAIR_BASE_HOME:?}"/*; fi
    else
        echo "  > [CANCEL] Installation aborted by user."
        exit 0
    fi
fi

mkdir -p "$LOCAL_CONFIG_PATH" "$REAL_PG_PATH"
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    ln -snf "$REAL_PG_PATH" "$LINK_PG_PATH"
fi

### ==============================================================================
### 4. Secrets
### ==============================================================================

ENV_FILE="${CLAIR_BASE_HOME}/clair-secrets.env"
cat <<EOF > "$ENV_FILE"
POSTGRESQL_USER=${PG_USER}
POSTGRESQL_PASSWORD=${PG_PASSWORD}
POSTGRESQL_DATABASE=${PG_DB_NAME}
POSTGRESQL_ADMIN_PASSWORD=${PG_ADMIN_PASSWORD}
EOF
chmod 600 "$ENV_FILE"

### ==============================================================================
### 5. Deployment: PostgreSQL
### ==============================================================================

echo "Deploying Components..."

echo "  > Starting PostgreSQL..."
chown -R 26:26 "$REAL_PG_PATH"

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
pg_exec_cmd="podman exec -it $PG_CONTAINER_NAME /bin/bash -c \"psql -U $PG_USER -d $PG_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS \\\"uuid-ossp\\\";'\""
eval "$pg_exec_cmd"

### ==============================================================================
### 6. Clair Configuration
### ==============================================================================

echo "Generating Clair Config..."
CONFIG_FILE="${LOCAL_CONFIG_PATH}/config.yaml"
TRUST_CERT_FILE="${LOCAL_CONFIG_PATH}/clair-trust.crt"

if [[ -f "/etc/pki/tls/certs/ca-bundle.crt" ]]; then
    cat /etc/pki/tls/certs/ca-bundle.crt "$ROOT_CA_PATH" > "$TRUST_CERT_FILE"
else
    cp "$ROOT_CA_PATH" "$TRUST_CERT_FILE"
fi

DB_PORT=$(get_port_number "$DB_PUBLISH_PORT" "$PG_INT_PORT")

cat <<EOF > "$CONFIG_FILE"
http_listen_addr: :${CLAIR_INT_HTTP}
introspection_addr: :${CLAIR_INT_INTRO}
log_level: info
indexer:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  scanlock_retry: 10
  layer_scan_concurrency: 5
  migrations: true
matcher:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  max_conn_pool: 100
  migrations: true
  indexer_addr: http://localhost:${CLAIR_INT_HTTP}
notifier:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  migrations: true
  indexer_addr: http://localhost:${CLAIR_INT_HTTP}
  matcher_addr: http://localhost:${CLAIR_INT_HTTP}
  poll_interval: 5m
  delivery_interval: 1m
auth:
  psk:
    key: "${CLAIR_PSK}"
    iss: ["quay"]
metrics:
  name: "prometheus"
EOF

chown -R 1001:1001 "$LOCAL_CONFIG_PATH"
chmod 644 "$CONFIG_FILE" "$TRUST_CERT_FILE"

### ==============================================================================
### 7. Run Clair Container
### ==============================================================================

echo ""
echo "Constructing Clair command..."

HTTP_ARG=$(get_podman_port_arg "$CLAIR_PUBLISH_HTTP" "$CLAIR_INT_HTTP" "false")
INTRO_ARG=$(get_podman_port_arg "$CLAIR_PUBLISH_INTRO" "$CLAIR_INT_INTRO" "true")

podman_clair_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$CLAIR_CONTAINER_NAME"
    "--cpus" "${CLAIR_CPU}"
    "--memory" "${CLAIR_MEM}"
    "--env" "SSL_CERT_FILE=/config/clair-trust.crt"
    $HTTP_ARG
    $INTRO_ARG
    "--volume" "${LOCAL_CONFIG_PATH}:/config:Z"
    "$CLAIR_IMAGE"
    "-conf" "/config/config.yaml"
    "-mode" "combo"
)

podman rm -f "$CLAIR_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Clair Command:"
echo "${podman_clair_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_clair_cmd[@]}"

echo "  > Clair Started."

### ==============================================================================
### 8. Systemd & Firewall
### ==============================================================================

echo ""
echo "Configuring Systemd & Firewall..."

FW_PORTS=(
    $(get_port_number "$CLAIR_PUBLISH_HTTP" "")
    $(get_port_number "$CLAIR_PUBLISH_INTRO" "")
    $(get_port_number "$DB_PUBLISH_PORT" "")
)

for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" =~ ^54 ]]; then TYPE="postgresql_port_t"; else TYPE="http_port_t"; fi
        semanage port -a -t $TYPE -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

cd /etc/systemd/system || exit
podman generate systemd --new --files --name "$PG_CONTAINER_NAME" >/dev/null
podman generate systemd --new --files --name "$CLAIR_CONTAINER_NAME" >/dev/null

CLAIR_SVC="container-${CLAIR_CONTAINER_NAME}.service"
if [[ -f "$CLAIR_SVC" ]] && ! grep -q "Requires=container-${PG_CONTAINER_NAME}.service" "$CLAIR_SVC"; then
     sed -i "/^After=/ s/$/ container-${PG_CONTAINER_NAME}.service/" "$CLAIR_SVC"
     sed -i "/^After=/a Requires=container-${PG_CONTAINER_NAME}.service" "$CLAIR_SVC"
fi

systemctl daemon-reload
systemctl enable "container-${PG_CONTAINER_NAME}" "container-${CLAIR_CONTAINER_NAME}"

### ==============================================================================
### 9. Generate Start Script
### ==============================================================================

START_SCRIPT="${CLAIR_BASE_HOME}/start-clair.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
ENV_FILE="${ENV_FILE}"
echo "Stopping containers..."
podman rm -f ${PG_CONTAINER_NAME} ${CLAIR_CONTAINER_NAME} 2>/dev/null || true

echo "Starting PostgreSQL..."
${podman_pg_cmd[*]}

sleep 5
echo "Starting Clair..."
${podman_clair_cmd[*]}

echo "Clair services started."
EOF
chmod 700 "$START_SCRIPT"

echo "  > Script created: $START_SCRIPT"
echo "----------------------------------------------------------------"
echo " [SUCCESS] Clair Installation Complete"
echo "----------------------------------------------------------------"
echo ""