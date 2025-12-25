#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
QUAY_HOST_NAME="quay.cloudpang.lan"
CLAIR_HOST_NAME="clair.cloudpang.lan"
BASE_HOME="/opt/quay-clair"

### Data Directories
QUAY_CLAIR_DATA_DIR="/data/quay-clair"

### Root CA (Optional)
ROOT_CA_PATH="/root/ocp4/support-system/custom-certs/rootCA/rootCA.crt"

### Certificate for Quay
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
QUAY_CUSTOM_CERT="" # Leave empty to auto-detect
QUAY_CUSTOM_KEY=""

### Images
QUAY_IMAGE="registry.redhat.io/quay/quay-rhel8:v3.15.2"
CLAIR_IMAGE="registry.redhat.io/quay/clair-rhel8:v3.15.2"
PG_IMAGE="registry.redhat.io/rhel8/postgresql-15"
REDIS_IMAGE="registry.redhat.io/rhel8/redis-6"

### Container Names
Q_CNAME="quay"
Q_PG_CNAME="postgresql-quay"
Q_REDIS_CNAME="redis-quay"
Q_CFG_EDITOR_CNAME="quay-config-editor"

C_CNAME="clair"
C_PG_CNAME="postgresql-clair"

### Credentials
Q_PG_USER="quay"
Q_PG_PASS="redhat1!"
Q_PG_ADM_PASS="redhat1!"
Q_REDIS_PASS="redhat1!"

C_PG_USER="clair"
C_PG_PASS="redhat1!"
C_PG_ADM_PASS="redhat1!"

### Database
Q_PG_DB="quay"
C_PG_DB="clair"

### Port Settings
### [NOTE] If you set just "IP", it maps to the INTERNAL PORT (e.g. 8080).
### If you want port 80, set "172.16.120.28:80"
TARGET_IP="172.16.120.28"

Q_EDITOR_PORT="8082"

Q_PUB_HTTP=""
Q_PUB_HTTPS="$TARGET_IP"
Q_PUB_PG="$TARGET_IP"
Q_PUB_REDIS="$TARGET_IP"

C_PUB_HTTP="$TARGET_IP"
C_PUB_INTRO="$TARGET_IP"
C_PUB_PG="$TARGET_IP:5433"

### Internal Ports (Do NOT change these unless you know the Image internals)
Q_INT_HTTP="8080"
Q_INT_HTTPS="8443"
Q_INT_PG="5432"
Q_INT_REDIS="6379"

C_INT_HTTP="8081"
C_INT_INTRO="8088"
C_INT_PG="5432"

### Resource Limits (Updated to 8g to prevent OOM)
Q_RES="--cpus 4 --memory 8g"
Q_PG_RES="--cpus 4 --memory 6g"
Q_REDIS_RES="--cpus 2 --memory 2g"

C_RES="--cpus 2 --memory 2g"
C_PG_RES="--cpus 2 --memory 4g"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### Helper: Extract Port Number
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

### Helper: Generate -p Argument
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

### Helper: Stop Systemd Services
cleanup_systemd_services() {
    local containers="$1"
    echo "  > Cleaning up Systemd services and Containers..."

    for ctr in $containers; do
        svc_name="container-${ctr}.service"

        ### 1. Stop and Disable Service if active/enabled
        if systemctl is-active --quiet "$svc_name"; then
            echo "    - Stopping service: $svc_name"
            systemctl stop "$svc_name"
        else
            echo "    - Stopping service: $ctr"
            podman stop $ctr
        fi
        if systemctl is-enabled --quiet "$svc_name"; then
            echo "    - Disabling service: $svc_name"
            systemctl disable "$svc_name"
        fi

        ### 2. Force remove container (Double safety)
        podman rm -f "$ctr" >/dev/null 2>&1

        ### 3. Remove unit file
        if [[ -f "/etc/systemd/system/$svc_name" ]]; then
            rm -f "/etc/systemd/system/$svc_name"
        fi
    done

    systemctl daemon-reload
    systemctl reset-failed
}

check_command() { if [[ $1 -ne 0 ]]; then echo "[CRITICAL ERROR] Exit Code $1. Aborting."; exit $1; fi; }

wait_for_container() {
    local ctr_name=$1
    local max_retries=10; local count=0
    echo -n "   > Waiting for $ctr_name to be healthy..."
    while [[ $count -lt $max_retries ]]; do
        if podman ps --format "{{.Names}}" | grep -q "^${ctr_name}$"; then echo " [OK]"; return 0; fi
        echo -n "."; sleep 2; ((count++))
    done
    echo " [FAILED]"; podman logs "$ctr_name" | tail -n 20; exit 1
}

### 1. Prerequisite Checks
if [[ $EUID -ne 0 ]]; then echo "[ERROR] Run as root."; exit 1; fi
for cmd in podman setfacl uuidgen; do if ! command -v $cmd &> /dev/null; then dnf install -y $cmd; fi; done
if ! grep -q "${QUAY_HOST_NAME}" /etc/hosts; then echo "[ERROR] ${QUAY_HOST_NAME} not in /etc/hosts"; exit 1; fi
if ! grep -q "${CLAIR_HOST_NAME}" /etc/hosts; then echo "[ERROR] ${CLAIR_HOST_NAME} not in /etc/hosts"; exit 1; fi

### Conflict Check Logic
echo "Checking for port conflicts..."

# Resolve DB Ports
RESOLVED_Q_PG=$(get_port_number "$Q_PUB_PG" "$Q_INT_PG")
RESOLVED_C_PG=$(get_port_number "$C_PUB_PG" "$C_INT_PG")

if [[ "$RESOLVED_Q_PG" == "$RESOLVED_C_PG" ]]; then
    echo "[CRITICAL ERROR] Port Conflict Detected!"
    echo "  > Quay DB Port:  $RESOLVED_Q_PG"
    echo "  > Clair DB Port: $RESOLVED_C_PG"
    exit 1
fi

# Check Editor Port against all other services
CHECK_LIST=(
    "$Q_PUB_HTTP:$Q_INT_HTTP"
    "$Q_PUB_HTTPS:$Q_INT_HTTPS"
    "$Q_PUB_REDIS:$Q_INT_REDIS"
    "$C_PUB_HTTP:$C_INT_HTTP"
    "$C_PUB_INTRO:$C_INT_INTRO"
    "$Q_PUB_PG:$Q_INT_PG"
    "$C_PUB_PG:$C_INT_PG"
)

for ITEM in "${CHECK_LIST[@]}"; do
    CONF_VAL="${ITEM%%:*}"
    DEF_PORT="${ITEM##*:}"
    RESOLVED_PORT=$(get_port_number "$CONF_VAL" "$DEF_PORT")

    if [[ -n "$RESOLVED_PORT" ]] && [[ "$Q_EDITOR_PORT" == "$RESOLVED_PORT" ]]; then
        echo "[CRITICAL ERROR] Port Conflict Detected!"
        echo "  > Config Editor Port ($Q_EDITOR_PORT) conflicts with Service Port ($RESOLVED_PORT)."
        exit 1
    fi
done
echo "  > [OK] No port conflicts detected."

### 2. Operation Mode
echo "=================================================================="
echo " [SELECT MODE]"
echo "=================================================================="
echo " 1) Fresh Install (WARNING: Wipes ALL Data)"
echo " 2) Update / Reconfigure (Keeps Data, Refreshes Certs/Containers)"
read -p " Select [1 or 2]: " OP_MODE
[[ "$OP_MODE" != "1" && "$OP_MODE" != "2" ]] && exit 1

### 3. Directory Setup
echo "Configuring Directories..."

Q_CFG_PATH="${BASE_HOME}/quay-config"
C_CFG_PATH="${BASE_HOME}/clair-config"
Q_ENV_PATH="${BASE_HOME}/quay-env"
C_ENV_PATH="${BASE_HOME}/clair-env"

if [[ -n "$QUAY_CLAIR_DATA_DIR" ]] && [[ "$QUAY_CLAIR_DATA_DIR" != "$BASE_HOME" ]]; then
    IS_SPLIT_STORAGE=true
    REAL_DATA_ROOT="$QUAY_CLAIR_DATA_DIR"
else
    IS_SPLIT_STORAGE=false
    REAL_DATA_ROOT="$BASE_HOME"
fi

REAL_Q_STOR="${REAL_DATA_ROOT}/quay-storage"
REAL_Q_PG="${REAL_DATA_ROOT}/quay-postgres"
REAL_Q_REDIS="${REAL_DATA_ROOT}/quay-redis"
REAL_C_PG="${REAL_DATA_ROOT}/clair-postgres"

LINK_Q_STOR="${BASE_HOME}/quay-storage"
LINK_Q_PG="${BASE_HOME}/quay-postgres"
LINK_Q_REDIS="${BASE_HOME}/quay-redis"
LINK_C_PG="${BASE_HOME}/clair-postgres"

ALL_CNAMES="$Q_CNAME $C_CNAME $Q_PG_CNAME $C_PG_CNAME $Q_REDIS_CNAME"

### [MODE 1] Full Cleanup
if [[ "$OP_MODE" == "1" ]]; then
    echo "  > [FRESH INSTALL] Cleaning up old environment..."

    cleanup_systemd_services "$ALL_CNAMES"

    if [[ -d "$REAL_DATA_ROOT" && "$REAL_DATA_ROOT" != "/" ]]; then
        echo "    - Wiping Real Data in: $REAL_DATA_ROOT"
        rm -rf "${REAL_Q_STOR:?}"/* "${REAL_Q_PG:?}"/* "${REAL_Q_REDIS:?}"/* "${REAL_C_PG:?}"/*
    fi

    if [[ -d "$BASE_HOME" ]]; then
        echo "    - Wiping Configs in: $BASE_HOME"
        rm -rf "${Q_CFG_PATH:?}"/* "${Q_ENV_PATH:?}"/* "${C_CFG_PATH:?}"/* "${C_ENV_PATH:?}"/*
        rm -f "$LINK_Q_STOR" "$LINK_Q_PG" "$LINK_Q_REDIS" "$LINK_C_PG"
        if [[ "$IS_SPLIT_STORAGE" == "false" ]]; then
             rm -rf "$LINK_Q_STOR" "$LINK_Q_PG" "$LINK_Q_REDIS" "$LINK_C_PG"
        fi
    fi
fi

### [MODE 2] Cleanup Containers only
if [[ "$OP_MODE" == "2" ]]; then
    echo "  > [UPDATE MODE] Stopping existing containers..."
    # [NEW] Stop Systemd Services First
    cleanup_systemd_services "$ALL_CNAMES"
fi

mkdir -p "$Q_CFG_PATH" "$Q_ENV_PATH" "$C_CFG_PATH" "$C_ENV_PATH"
mkdir -p "$REAL_Q_STOR" "$REAL_Q_PG" "$REAL_Q_REDIS" "$REAL_C_PG"

if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    echo "  > [INFO] Split Storage Detected. Creating Symlinks in $BASE_HOME..."
    ln -sfn "$REAL_Q_STOR"  "$LINK_Q_STOR"
    ln -sfn "$REAL_Q_PG"    "$LINK_Q_PG"
    ln -sfn "$REAL_Q_REDIS" "$LINK_Q_REDIS"
    ln -sfn "$REAL_C_PG"    "$LINK_C_PG"
fi

setfacl -m u:1001:-wx "$REAL_Q_STOR" "$REAL_Q_REDIS" "$Q_CFG_PATH" "$Q_ENV_PATH" "$C_CFG_PATH" "$C_ENV_PATH"
setfacl -m u:26:-wx "$REAL_Q_PG" "$REAL_C_PG"

if [[ -n "$Q_PUB_HTTPS" ]]; then
    S_CERT=${QUAY_CUSTOM_CERT:-"${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.crt"}
    S_KEY=${QUAY_CUSTOM_KEY:-"${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.key"}
    if [[ -f "$S_CERT" && -f "$S_KEY" ]]; then
        echo "  > Copying/Refreshing SSL Certificates..."
        cp "$S_CERT" "${Q_CFG_PATH}/ssl.cert"
        cp "$S_KEY" "${Q_CFG_PATH}/ssl.key"
        chmod 644 "${Q_CFG_PATH}/ssl.cert"; chmod 600 "${Q_CFG_PATH}/ssl.key"
        chown 1001:1001 "${Q_CFG_PATH}/ssl.cert" "${Q_CFG_PATH}/ssl.key"
    else
        echo "[ERROR] Cert files not found: $S_CERT"; exit 1
    fi
fi

### 4. Secrets Generation
echo "Generating/Refreshing Secrets..."

echo "POSTGRESQL_USER=${Q_PG_USER}
POSTGRESQL_PASSWORD=${Q_PG_PASS}
POSTGRESQL_DATABASE=${Q_PG_DB}
POSTGRESQL_ADMIN_PASSWORD=${Q_PG_ADM_PASS}" > "${Q_ENV_PATH}/quay-pg.env"

echo "POSTGRESQL_USER=${C_PG_USER}
POSTGRESQL_PASSWORD=${C_PG_PASS}
POSTGRESQL_DATABASE=${C_PG_DB}
POSTGRESQL_ADMIN_PASSWORD=${C_PG_ADM_PASS}" > "${C_ENV_PATH}/clair-pg.env"

echo "REDIS_PASSWORD=${Q_REDIS_PASS}" > "${Q_ENV_PATH}/redis.env"

echo "QUAY_PG_PASSWORD=${Q_PG_PASS}
REDIS_PASSWORD=${Q_REDIS_PASS}" > "${Q_ENV_PATH}/quay-app.env"

echo "CLAIR_PG_PASSWORD=${C_PG_PASS}" > "${C_ENV_PATH}/clair-app.env"

chmod 600 -R "${Q_ENV_PATH}" "${C_ENV_PATH}"

### 5. Firewall
echo "Configuring Firewall..."
### Explicitly calculate all ports to open, handling defaults
PORTS_TO_OPEN=""
P=$(get_port_number "$Q_PUB_HTTP" "$Q_INT_HTTP");   [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$Q_PUB_HTTPS" "$Q_INT_HTTPS"); [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$Q_PUB_PG" "$Q_INT_PG");       [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$Q_PUB_REDIS" "$Q_INT_REDIS"); [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$C_PUB_HTTP" "$C_INT_HTTP");   [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$C_PUB_INTRO" "$C_INT_INTRO"); [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"
P=$(get_port_number "$C_PUB_PG" "$C_INT_PG");       [[ -n "$P" ]] && PORTS_TO_OPEN="$PORTS_TO_OPEN $P"

for P in $PORTS_TO_OPEN; do firewall-cmd --permanent --zone=public --add-port=${P}/tcp >/dev/null 2>&1; done
firewall-cmd --reload >/dev/null

### 6. Deploy Databases
echo "Deploying Databases..."

### 6.1 Quay DB
Q_PG_PORT_ARG=$(get_podman_port_arg "$Q_PUB_PG" "$Q_INT_PG" "false")
podman rm -f "$Q_PG_CNAME" 2>/dev/null

CMD_Q_PG=(
    "podman" "run" "-d"
    "--name" "$Q_PG_CNAME"
    $Q_PG_RES
    "--env-file" "${Q_ENV_PATH}/quay-pg.env"
)
if [[ -n "$Q_PG_PORT_ARG" ]]; then
    CMD_Q_PG+=($Q_PG_PORT_ARG)
fi
CMD_Q_PG+=(
    "-v" "${REAL_Q_PG}:/var/lib/pgsql/data:Z"
    "$PG_IMAGE"
)

CMD_Q_PG_STR="${CMD_Q_PG[*]}"

echo "  > Executing: $Q_PG_CNAME"
echo "    >  $CMD_Q_PG_STR"
"${CMD_Q_PG[@]}"
wait_for_container "$Q_PG_CNAME"

### 6.2 Redis
Q_REDIS_PORT_ARG=$(get_podman_port_arg "$Q_PUB_REDIS" "$Q_INT_REDIS" "false")
podman rm -f "$Q_REDIS_CNAME" 2>/dev/null

CMD_Q_REDIS=(
    "podman" "run" "-d"
    "--name" "$Q_REDIS_CNAME"
    $Q_REDIS_RES
    "--env-file" "${Q_ENV_PATH}/redis.env"
)
if [[ -n "$Q_REDIS_PORT_ARG" ]]; then
    CMD_Q_REDIS+=($Q_REDIS_PORT_ARG)
fi
CMD_Q_REDIS+=(
    "-v" "${REAL_Q_REDIS}:/data:Z"
    "$REDIS_IMAGE"
)

CMD_Q_REDIS_STR="${CMD_Q_REDIS[*]}"

echo "  > Executing: $Q_REDIS_CNAME"
echo "    >  $CMD_Q_REDIS_STR"
"${CMD_Q_REDIS[@]}"
wait_for_container "$Q_REDIS_CNAME"

### 6.3 Clair DB
C_PG_PORT_ARG=$(get_podman_port_arg "$C_PUB_PG" "$C_INT_PG" "false")
podman rm -f "$C_PG_CNAME" 2>/dev/null

CMD_C_PG=(
    "podman" "run" "-d"
    "--name" "$C_PG_CNAME"
    $C_PG_RES
    "--env-file" "${C_ENV_PATH}/clair-pg.env"
)
if [[ -n "$C_PG_PORT_ARG" ]]; then
    CMD_C_PG+=($C_PG_PORT_ARG)
fi
CMD_C_PG+=(
    "-v" "${REAL_C_PG}:/var/lib/pgsql/data:Z"
    "$PG_IMAGE"
)

CMD_C_PG_STR="${CMD_C_PG[*]}"

echo "  > Executing: $C_PG_CNAME"
echo "    >  $CMD_C_PG_STR"
"${CMD_C_PG[@]}"
wait_for_container "$C_PG_CNAME"

### [MODE 1] Full Cleanup
if [[ "$OP_MODE" == "1" ]]; then
    echo "  > Ensuring DB Extensions..."
    sleep 5
    podman exec "$Q_PG_CNAME" psql -U "$Q_PG_USER" -d "$Q_PG_DB" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" >/dev/null 2>&1
    podman exec "$C_PG_CNAME" psql -U "$C_PG_USER" -d "$C_PG_DB" -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";" >/dev/null 2>&1
fi

### 7. Config Editor Phase (Conditional)
RUN_EDITOR="y"
if [[ "$OP_MODE" == "2" ]]; then
    read -p " [UPDATE MODE] Do you want to run the Config Editor to modify settings? [y/N]: " ask_editor
    if [[ ! "$ask_editor" =~ ^[Yy]$ ]]; then RUN_EDITOR="n"; fi
fi

if [[ "$RUN_EDITOR" == "y" ]]; then
    echo ""
    echo "=================================================================="
    echo " [PHASE 1] Quay Config Editor"
    echo "=================================================================="

    podman rm -f "$Q_CFG_EDITOR_CNAME" 2>/dev/null

    CMD_EDITOR=(
        "podman" "run" "-d"
        "--name" "$Q_CFG_EDITOR_CNAME"
        "-p" "${Q_EDITOR_PORT}:8080"
        "-v" "${Q_CFG_PATH}:/conf/stack:Z"
        "-v" "${REAL_Q_STOR}:/datastorage:Z"
        "$QUAY_IMAGE" "config" "secret"
    )

    CMD_EDITOR_STR="${CMD_EDITOR[*]}"

    echo "  > Executing:"
    echo "    > $CMD_EDITOR_STR"
    "${CMD_EDITOR[@]}"
    wait_for_container "$Q_CFG_EDITOR_CNAME"

    ### 1. DB Host/Port
    DB_HOST="${Q_PUB_PG%%:*}"
    DB_PORT=$(get_port_number "$Q_PUB_PG" "$Q_INT_PG")

    ### 2. Redis Host/Port
    REDIS_HOST="${Q_PUB_REDIS%%:*}"
    REDIS_PORT=$(get_port_number "$Q_PUB_REDIS" "$Q_INT_REDIS")

    ### 3. Clair Port
    CLAIR_PORT=$(get_port_number "$C_PUB_HTTP" "$C_INT_HTTP")

    echo "------------------------------------------------------------------"
    echo " ACTION REQUIRED:"
    echo " 1. Browser: http://${TARGET_IP}:${Q_EDITOR_PORT}"
    echo " 2. Login: quayconfig / secret"
    echo " 3. Verify/Set:"
    echo "    3.1. Server Configuration:"
    echo "         - Server Hostname: $QUAY_HOST_NAME"
    echo "    3.2. Database:"
    echo "         - Database Type: Postgres"
    echo "         - Database Server:  ${DB_HOST}:${DB_PORT}"
    echo "         - Username: $Q_PG_USER"
    echo "         - Password: $Q_PG_PASS"
    echo "         - Database Name: $Q_PG_DB"
    echo "    3.3. Redis:"
    echo "         - Redis Hostname: $REDIS_HOST"
    echo "         - Redis Port: $REDIS_PORT"
    echo "         - Redis Password: $Q_REDIS_PASS"
    echo "    3.4. Security Scanner: Enable 'Clair'"
    echo "         - Security Scanner Endpoint: http://${CLAIR_HOST_NAME}:${CLAIR_PORT}"
    echo "         - Security Scanner PSK: \"Click 'Generate PSK', copy the generated key, and paste it into the prompt below\""
    echo " 4. Click 'Validate Configuration Changes'"
    echo "    - Download 'quay-config.tar.gz' -> Extract -> Open 'config.yaml'"
    echo "    ------------------------------------------------------------------"
    echo "    [MANUAL PASTE]"
    echo "    Run this in another terminal, paste content, save, and quit:"
    echo "    vi ${Q_CFG_PATH}/config.yaml"
    echo "    ------------------------------------------------------------------"

    while [[ -z "$INPUT_PSK" ]]; do
        read -p " > Enter the PSK you used in Config Editor: " INPUT_PSK
    done
    FINAL_PSK="$INPUT_PSK"

    read -p " > Press ENTER after saving config.yaml... "
    if [[ ! -f "${Q_CFG_PATH}/config.yaml" ]]; then echo "[ERROR] config.yaml not found."; exit 1; fi

    chown -R 1001:1001 "${Q_CFG_PATH}"
    chmod 644 "${Q_CFG_PATH}/config.yaml"
    if [[ -f "${Q_CFG_PATH}/ssl.key" ]]; then chmod 600 "${Q_CFG_PATH}/ssl.key"; fi

    podman stop "$Q_CFG_EDITOR_CNAME" >/dev/null; podman rm "$Q_CFG_EDITOR_CNAME" >/dev/null
else
    FINAL_PSK=$(grep "SECURITY_SCANNER_V4_PSK" "${Q_CFG_PATH}/config.yaml" | awk '{print $2}' | tr -d '"')
    echo "  > Using existing PSK from config: $FINAL_PSK"
fi

### 8. Clair Configuration & Deploy
echo "Configuring Clair..."
cat /dev/null > "${C_CFG_PATH}/clair-trust.crt"
[[ -f "$ROOT_CA_PATH" ]] && cat "$ROOT_CA_PATH" >> "${C_CFG_PATH}/clair-trust.crt"
[[ -f "${Q_CFG_PATH}/ssl.cert" ]] && cat "${Q_CFG_PATH}/ssl.cert" >> "${C_CFG_PATH}/clair-trust.crt"

### Get Clair DB Port correctly
C_DB_P=$(get_port_number "$C_PUB_PG" "$C_INT_PG")

cat <<EOF > "${C_CFG_PATH}/config.yaml"
http_listen_addr: :${C_INT_HTTP}
introspection_addr: :${C_INT_INTRO}
log_level: info
indexer:
  connstring: host=${CLAIR_HOST_NAME} port=${C_DB_P} dbname=${C_PG_DB} user=${C_PG_USER} password=${C_PG_PASS} sslmode=disable
  migrations: true
  scanlock_retry: 10
  layer_scan_concurrency: 5
matcher:
  connstring: host=${CLAIR_HOST_NAME} port=${C_DB_P} dbname=${C_PG_DB} user=${C_PG_USER} password=${C_PG_PASS} sslmode=disable
  migrations: true
  max_conn_pool: 100
  indexer_addr: http://localhost:${C_INT_HTTP}
notifier:
  connstring: host=${CLAIR_HOST_NAME} port=${C_DB_P} dbname=${C_PG_DB} user=${C_PG_USER} password=${C_PG_PASS} sslmode=disable
  migrations: true
  indexer_addr: http://localhost:${C_INT_HTTP}
  matcher_addr: http://localhost:${C_INT_HTTP}
  poll_interval: 5m
  delivery_interval: 1m
auth:
  psk:
    key: "${FINAL_PSK}"
    iss: ["quay"]
metrics:
  name: "prometheus"
EOF
chown -R 1001:1001 "${C_CFG_PATH}"

echo "Deploying Clair..."
C_HTTP_ARG=$(get_podman_port_arg "$C_PUB_HTTP" "$C_INT_HTTP" "false")
C_INTRO_ARG=$(get_podman_port_arg "$C_PUB_INTRO" "$C_INT_INTRO" "true")

podman rm -f "$C_CNAME" 2>/dev/null

CMD_CLAIR=(
    "podman" "run" "-d"
    "--name" "$C_CNAME"
    $C_RES
    "--env-file" "${C_ENV_PATH}/clair-app.env"
    "--env" "SSL_CERT_FILE=/config/clair-trust.crt"
)
[[ -n "$C_HTTP_ARG" ]] && CMD_CLAIR+=($C_HTTP_ARG)
[[ -n "$C_INTRO_ARG" ]] && CMD_CLAIR+=($C_INTRO_ARG)
CMD_CLAIR+=(
    "-v" "${C_CFG_PATH}:/config:Z"
    "$CLAIR_IMAGE"
    "-conf" "/config/config.yaml"
    "-mode" "combo"
)

CMD_CLAIR_STR="${CMD_CLAIR[*]}"

echo "  > Executing: $C_CNAME"
echo "    >  $CMD_CLAIR_STR"
"${CMD_CLAIR[@]}"
wait_for_container "$C_CNAME"

### 9. Deploy Quay
echo "Deploying Quay..."
Q_HTTPS_ARG=$(get_podman_port_arg "$Q_PUB_HTTPS" "$Q_INT_HTTPS" "true")
Q_HTTP_ARG=$(get_podman_port_arg "$Q_PUB_HTTP" "$Q_INT_HTTP" "true")

podman rm -f "$Q_CNAME" 2>/dev/null

CMD_QUAY=(
    "podman" "run" "-d"
    "--name" "$Q_CNAME"
    $Q_RES
    "--env-file" "${Q_ENV_PATH}/quay-app.env"
)
[[ -n "$Q_HTTPS_ARG" ]] && CMD_QUAY+=($Q_HTTPS_ARG)
[[ -n "$Q_HTTP_ARG" ]] && CMD_QUAY+=($Q_HTTP_ARG)
CMD_QUAY+=(
    "-v" "${Q_CFG_PATH}:/conf/stack:Z"
    "-v" "${LINK_Q_STOR}:/datastorage:Z"
    "$QUAY_IMAGE"
)

CMD_QUAY_STR="${CMD_QUAY[*]}"

echo "  > Executing: $Q_CNAME"
echo "    >  $CMD_QUAY_STR"
"${CMD_QUAY[@]}"
wait_for_container "$Q_CNAME"

### 10. Systemd
echo "Configuring Systemd..."
cd /etc/systemd/system
for ctr in $Q_PG_CNAME $Q_REDIS_CNAME $Q_CNAME $C_PG_CNAME $C_CNAME; do
    podman generate systemd --new --files --name "$ctr" >/dev/null
done
### Dependencies
sed -i "/^After=/ s/$/ container-${Q_PG_CNAME}.service container-${Q_REDIS_CNAME}.service/" "container-${Q_CNAME}.service"
sed -i "/^After=/ s/$/ container-${C_PG_CNAME}.service/" "container-${C_CNAME}.service"

systemctl daemon-reload
systemctl enable --now "container-${Q_PG_CNAME}" "container-${Q_REDIS_CNAME}" "container-${C_PG_CNAME}"
systemctl enable --now "container-${C_CNAME}" "container-${Q_CNAME}"

### 11. Start/Stop Scripts
echo "Generating Start/Stop Scripts..."
cat <<EOF > "${BASE_HOME}/start-quay-stack.sh"
#!/bin/bash
echo "Starting Quay Stack..."
systemctl start container-${Q_PG_CNAME}
systemctl start container-${C_PG_CNAME}
systemctl start container-${Q_REDIS_CNAME}
sleep 5
systemctl start container-${C_CNAME}
systemctl start container-${Q_CNAME}
echo "Done."
EOF
chmod 700 "${BASE_HOME}/start-quay-stack.sh"

cat <<EOF > "${BASE_HOME}/stop-quay-stack.sh"
#!/bin/bash
echo "Stopping Quay Stack..."
systemctl stop container-${Q_CNAME}
systemctl stop container-${C_CNAME}
sleep 5
systemctl stop container-${Q_REDIS_CNAME}
systemctl stop container-${C_PG_CNAME}
systemctl stop container-${Q_PG_CNAME}
echo "Done."
EOF
chmod 700 "${BASE_HOME}/stop-quay-stack.sh"

### 12. Stop Script
cleanup_systemd_services "$ALL_CNAMES"

### 13. Restart Quay & Clair
${BASE_HOME}/start-quay-stack.sh

### 14. Display Info
echo "----------------------------------------------------------------"
echo " [SUCCESS] Installation Complete"
echo "----------------------------------------------------------------"
echo " > Start Script: ${BASE_HOME}/start-quay-stack.sh"
echo " > Stop Script:  ${BASE_HOME}/stop-quay-stack.sh"
echo ""