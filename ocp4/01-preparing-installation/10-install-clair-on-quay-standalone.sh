#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
CLAIR_HOST_NAME="clair.cloudpang.lan"
CLAIR_BASE_HOME="/opt/clair-quay"

### 2. Images (Red Hat Registry)
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
### These ports will be injected into config.yaml AND Podman port mapping
CLAIR_PUBLISH_HTTP="172.16.120.28:8081"
CLAIR_PUBLISH_INTRO="172.16.120.28:8088"
DB_PUBLISH_PORT="172.16.120.28:5433"

### 7. Resource Limits
CLAIR_CPU="2"
CLAIR_MEM="4g"
PG_CPU="2"
PG_MEM="2g"

### 8. Quay Integration (Pre-Shared Key)
CLAIR_PSK=""

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Helper & Prerequisite
### ==============================================================================

get_port_number() { local input=$1; echo "${input##*:}"; }

if [[ $EUID -ne 0 ]]; then echo "[ERROR] Run as root."; exit 1; fi

### Install required tools
for cmd in podman setfacl uuidgen base64; do
    if ! command -v $cmd &> /dev/null; then yum install -y $cmd; fi
done

### Verify Hostname
if ! grep -q "${CLAIR_HOST_NAME}" /etc/hosts; then
    echo "[ERROR] Hostname '${CLAIR_HOST_NAME}' NOT found in /etc/hosts."
    exit 1
fi

### ==============================================================================
### 2. Interactive Guide: Get PSK from Quay
### ==============================================================================

if [[ -z "$CLAIR_PSK" ]]; then
    echo ""
    echo "################################################################################"
    echo " [GUIDE] STEP 1: Generate Pre-Shared Key (PSK) from 'Red Hat Quay Setup'"
    echo "################################################################################"
    echo " To proceed, you need to generate a PSK using the running Quay Config Editor."
    echo ""
    echo " 1. Open your browser and access the Quay Config Editor."
    echo "    URL Example: http://<QUAY_HOSTNAME>:<PORT>"
    echo ""
    echo " 2. Scroll down to the 'Security Scanner' section."
    echo ""
    echo " 3. Check the box: [x] Enable Security Scanning"
    echo ""
    echo " 4. Click the button: [Generate PSK]"
    echo ""
    echo " 5. COPY the 'Secret Key' (Security Scanner PSK)."
    echo "    -> DO NOT click 'Validate Configuration Changes' yet."
    echo "################################################################################"
    echo ""

    read -p " > Paste the Secret Key (PSK) here: " CLAIR_PSK

    if [[ -z "$CLAIR_PSK" ]]; then
        echo "[ERROR] PSK is empty. Script aborted."
        exit 1
    fi
fi

### ==============================================================================
### 3. Directory Setup & Initialization Logic
### ==============================================================================

### Define Location Variables
LOCAL_CONFIG_PATH="${CLAIR_BASE_HOME}/config"
LINK_PG_PATH="${CLAIR_BASE_HOME}/postgres"

if [[ -n "$CLAIR_REAL_DATA_DIR" ]] && [[ "$CLAIR_REAL_DATA_DIR" != "$CLAIR_BASE_HOME" ]]; then
    REAL_PG_PATH="${CLAIR_REAL_DATA_DIR}/postgres"
    REAL_STORAGE_PATH="${CLAIR_REAL_DATA_DIR}/storage"
    IS_SPLIT_STORAGE=true
else
    REAL_PG_PATH="${CLAIR_BASE_HOME}/postgres"
    REAL_STORAGE_PATH="${CLAIR_BASE_HOME}/storage"
    IS_SPLIT_STORAGE=false
fi

echo ""
echo "Configuring Directories..."
echo "  [Base Home] Config Path  : $LOCAL_CONFIG_PATH"
echo "  [Real Data] Postgres DB  : $REAL_PG_PATH"
echo "  [Real Data] Tmp Storage  : $REAL_STORAGE_PATH"

### [Interactive Initialization Check]
DATA_EXISTS=false
if [[ -d "$REAL_PG_PATH" ]] && [[ "$(ls -A "$REAL_PG_PATH")" ]]; then DATA_EXISTS=true; fi
if [[ -d "$CLAIR_BASE_HOME" ]] && [[ "$(ls -A "$CLAIR_BASE_HOME")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Clair data found!"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data, DB, logs)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > [Check] Verifying container status..."
        RUNNING_CTRS=$(podman ps --format "{{.Names}}" | grep -E "^(${CLAIR_CONTAINER_NAME}|${PG_CONTAINER_NAME})$")

        if [[ -n "$RUNNING_CTRS" ]]; then
            echo "[ERROR] Active containers detected: $RUNNING_CTRS"
            echo "Please stop them manually using 'podman stop <container_name>'."
            exit 1
        fi

        echo "  > [Step 1] Cleaning Real Data..."
        podman rm "$CLAIR_CONTAINER_NAME" "$PG_CONTAINER_NAME" 2>/dev/null || true
        if [[ -d "$CLAIR_REAL_DATA_DIR" ]]; then rm -rf "${CLAIR_REAL_DATA_DIR:?}"/*; fi

        echo "  > [Step 2] Cleaning Base Home (Config, Symlinks)..."
        if [[ -d "$CLAIR_BASE_HOME" ]]; then rm -rf "${CLAIR_BASE_HOME:?}"/*; fi

        echo "  > [Check] All directories initialized."
    else
        echo "  > [CANCEL] Installation aborted by user."
        exit 0
    fi
fi

### Create Directories
mkdir -p "$LOCAL_CONFIG_PATH" "$REAL_STORAGE_PATH" "$REAL_PG_PATH"

if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    ln -snf "$REAL_PG_PATH" "$LINK_PG_PATH"
fi

### ==============================================================================
### 4. Create Security Environment File
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
### 5. Deploy PostgreSQL
### ==============================================================================

echo ""
echo "Deploying PostgreSQL..."
### Ensure Postgres User (UID 26) can write
chown -R 26:26 "$REAL_PG_PATH"

podman rm -f "$PG_CONTAINER_NAME" 2>/dev/null || true

podman run -d --rm \
    --name "$PG_CONTAINER_NAME" \
    --cpus "$PG_CPU" --memory "$PG_MEM" \
    --env-file "$ENV_FILE" \
    -p "${DB_PUBLISH_PORT}:5432" \
    --volume "${REAL_PG_PATH}:/var/lib/pgsql/data:Z" \
    "$PG_IMAGE"

echo "  > Waiting for DB (10s)..."
sleep 10

### Install uuid-ossp extension
pg_exec_cmd="podman exec -it $PG_CONTAINER_NAME /bin/bash -c \"psql -U $PG_USER -d $PG_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS \\\"uuid-ossp\\\";'\""
eval "$pg_exec_cmd"

### ==============================================================================
### 6. Generate Clair Configuration
### ==============================================================================

CONFIG_FILE="${LOCAL_CONFIG_PATH}/config.yaml"

DB_PORT_NUM=$(get_port_number "$DB_PUBLISH_PORT")
CLAIR_HTTP_PORT=$(get_port_number "$CLAIR_PUBLISH_HTTP")
CLAIR_INTRO_PORT=$(get_port_number "$CLAIR_PUBLISH_INTRO")

cat <<EOF > "$CONFIG_FILE"
http_listen_addr: :${CLAIR_HTTP_PORT}
introspection_addr: :${CLAIR_INTRO_PORT}
log_level: info

indexer:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT_NUM} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  scanlock_retry: 10
  layer_scan_concurrency: 5
  migrations: true

matcher:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT_NUM} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  max_conn_pool: 100
  migrations: true
  indexer_addr: http://localhost:${CLAIR_HTTP_PORT}

notifier:
  connstring: host=${CLAIR_HOST_NAME} port=${DB_PORT_NUM} dbname=${PG_DB_NAME} user=${PG_USER} password=${PG_PASSWORD} sslmode=disable
  migrations: true
  indexer_addr: http://localhost:${CLAIR_HTTP_PORT}
  matcher_addr: http://localhost:${CLAIR_HTTP_PORT}
  poll_interval: 5m
  delivery_interval: 1m

auth:
  psk:
    key: "${CLAIR_PSK}"
    iss: ["quay"]

metrics:
  name: "prometheus"
EOF

### Change ownership to Clair User (1001)
echo "  > Applying permissions for Clair User (UID 1001)..."
chown 1001:1001 "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

### Apply ownership to directories recursively
chown -R 1001:1001 "$LOCAL_CONFIG_PATH"
chown -R 1001:1001 "$REAL_STORAGE_PATH"

### ==============================================================================
### 8. Run Clair Container
### ==============================================================================

echo ""
echo "Deploying Clair..."

podman rm -f "$CLAIR_CONTAINER_NAME" 2>/dev/null || true

podman_clair_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$CLAIR_CONTAINER_NAME"
    "--cpus" "${CLAIR_CPU}"
    "--memory" "${CLAIR_MEM}"

    "-p" "${CLAIR_PUBLISH_HTTP}:${CLAIR_HTTP_PORT}"
    "-p" "${CLAIR_PUBLISH_INTRO}:${CLAIR_INTRO_PORT}"

    "--volume" "${LOCAL_CONFIG_PATH}:/config:Z"
    "--volume" "${REAL_STORAGE_PATH}:/tmp:Z"

    "$CLAIR_IMAGE"
    "-conf" "/config/config.yaml"
    "-mode" "combo"
)

echo "----------------------------------------------------------------"
echo "Clair Command:"
echo "${podman_clair_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_clair_cmd[@]}"

echo ""
echo "Clair Started."

### ==============================================================================
### 9. Generate Start Script
### ==============================================================================

START_SCRIPT="${CLAIR_BASE_HOME}/start-clair.sh"

cat <<EOF > "$START_SCRIPT"
#!/bin/bash
ENV_FILE="${ENV_FILE}"

echo "Starting PostgreSQL..."
podman run -d --rm --name ${PG_CONTAINER_NAME} \\
    --cpus ${PG_CPU} --memory ${PG_MEM} \\
    --env-file "\$ENV_FILE" \\
    -p ${DB_PUBLISH_PORT}:5432 \\
    --volume ${REAL_PG_PATH}:/var/lib/pgsql/data:Z \\
    ${PG_IMAGE}

sleep 5

echo "Starting Clair..."
podman run -d --rm --name ${CLAIR_CONTAINER_NAME} \\
    --cpus ${CLAIR_CPU} --memory ${CLAIR_MEM} \\
    -p ${CLAIR_PUBLISH_HTTP}:${CLAIR_HTTP_PORT} -p ${CLAIR_PUBLISH_INTRO}:${CLAIR_INTRO_PORT} \\
    --volume ${LOCAL_CONFIG_PATH}:/config:Z --volume ${REAL_STORAGE_PATH}:/tmp:Z \\
    ${CLAIR_IMAGE} -conf /config/config.yaml -mode combo
EOF

chmod 700 "$START_SCRIPT"
echo "  > Start script created: $START_SCRIPT"

### ==============================================================================
### 10. Systemd Registration & Firewall
### ==============================================================================

echo "Configuring Systemd & Firewall..."

### Firewall
FW_HTTP=$(get_port_number "$CLAIR_PUBLISH_HTTP")
FW_INTRO=$(get_port_number "$CLAIR_PUBLISH_INTRO")
FW_DB=$(get_port_number "$DB_PUBLISH_PORT")
for PORT in $FW_HTTP $FW_INTRO $FW_DB; do
    if [[ "$PORT" =~ ^54 ]]; then TYPE="postgresql_port_t"; else TYPE="http_port_t"; fi
    semanage port -a -t $TYPE -p tcp $PORT 2>/dev/null || true
    firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
done
firewall-cmd --reload >/dev/null

### Systemd
cd /etc/systemd/system || exit
podman generate systemd --new --files --name "$PG_CONTAINER_NAME" >/dev/null
podman generate systemd --new --files --name "$CLAIR_CONTAINER_NAME" >/dev/null

### Add dependency
CLAIR_SVC="container-${CLAIR_CONTAINER_NAME}.service"
if [[ -f "$CLAIR_SVC" ]]; then
    if ! grep -q "Requires=container-${PG_CONTAINER_NAME}.service" "$CLAIR_SVC"; then
         sed -i "/^After=/ s/$/ container-${PG_CONTAINER_NAME}.service/" "$CLAIR_SVC"
         sed -i "/^After=/a Requires=container-${PG_CONTAINER_NAME}.service" "$CLAIR_SVC"
    fi
fi

systemctl daemon-reload
systemctl enable "container-${PG_CONTAINER_NAME}"
systemctl enable "container-${CLAIR_CONTAINER_NAME}"

echo ""
echo "################################################################################"
echo " [GUIDE] STEP 2: Finalize Configuration in 'Red Hat Quay Setup'"
echo "################################################################################"
echo " 1. Return to the 'Red Hat Quay Setup' page in your browser."
echo ""
echo " 2. Locate the 'Security Scanner Endpoint' field."
echo "    Enter this URL: http://${CLAIR_HOST_NAME}:$(get_port_number "$CLAIR_PUBLISH_HTTP")"
echo ""
echo " 3. Click the [Validate Configuration Changes] button at the bottom of the page."
echo "    (Ensure all checks pass)"
echo ""
echo " 4. Finalize and Apply:"
echo "    -> Validate and download the configuration bundle (quay-config.tar.gz)."
echo "    -> Stop the Quay container that is running the configuration editor."
echo ""
echo " 5. Update Configuration on Host:"
echo "    -> Extract the new configuration bundle into your Red Hat Quay installation directory."
echo ""
echo " 6. Start the production Quay container:"
echo "################################################################################"
echo ""