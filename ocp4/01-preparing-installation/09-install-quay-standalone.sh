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
### Format supported: "Port" (e.g., "8443") or "IP:Port" (e.g., "192.168.1.10:8443")
QUAY_PUBLISH_HTTP="172.16.120.28:80"
QUAY_PUBLISH_HTTPS="172.16.120.28:443"
DB_PUBLISH_PORT="172.16.120.28:5432"
REDIS_PUBLISH_PORT="172.16.120.28:6379"

### 8. Resource Limits (Recommended for Production)
### Quay: At least 4GB recommended
QUAY_CPU="4"
QUAY_MEM="8g"

### DB: Needs good IO and Memory
PG_CPU="2"
PG_MEM="4g"

### Redis: Cache and events
REDIS_CPU="1"
REDIS_MEM="2g"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Helper: Parse Ports
### ==============================================================================

get_port_number() {
    local input=$1
    echo "${input##*:}"
}

### ==============================================================================
### 2. Prerequisite Checks & Host Config
### ==============================================================================

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run as root."
   exit 1
fi

echo "Checking Prerequisites..."

### Check required commands
for cmd in podman setfacl uuidgen; do
    if ! command -v $cmd &> /dev/null; then
        echo "  > Installing $cmd..."
        if [[ "$cmd" == "uuidgen" ]]; then
            dnf install -y util-linux
        else
            dnf install -y $cmd
        fi
    fi
done

### Verify /etc/hosts configuration
echo ""
echo "Verifying /etc/hosts configuration..."

if grep -q "${QUAY_HOST_NAME}" /etc/hosts; then
    echo "  > [OK] Hostname '${QUAY_HOST_NAME}' found in /etc/hosts."
else
    echo "  > [ERROR] Hostname '${QUAY_HOST_NAME}' NOT found in /etc/hosts."
    echo "  > Please configure /etc/hosts manually before running this script."
    echo "    Example: <Server_IP> ${QUAY_HOST_NAME}"
    exit 1
fi

### ==============================================================================
### 3. Certificate Resolution Logic
### ==============================================================================

echo ""
echo "Resolving certificate paths..."

if [[ -n "$QUAY_CUSTOM_CERT" ]]; then
    SOURCE_CERT="$QUAY_CUSTOM_CERT"
else
    SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.crt"
fi

if [[ -n "$QUAY_CUSTOM_KEY" ]]; then
    SOURCE_KEY="$QUAY_CUSTOM_KEY"
else
    SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${QUAY_HOST_NAME}.key"
fi

if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then
    echo "[ERROR] Certificate or Key file not found."
    echo "  Expected Cert: $SOURCE_CERT"
    echo "  Expected Key : $SOURCE_KEY"
    exit 1
fi
echo "  > Certificate found: $SOURCE_CERT"

### ==============================================================================
### 4. Directory Setup & Interactive Initialization
### ==============================================================================

### Define Location Variables
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

echo ""
echo "Configuring Directories..."
echo "  [Base Home] Config Path  : $LOCAL_CONFIG_PATH"
echo "  [Real Data] Storage Path : $REAL_STORAGE_PATH"
echo "  [Real Data] Postgres DB  : $REAL_PG_PATH"
echo "  [Real Data] Redis Data   : $REAL_REDIS_PATH"

### [Interactive Initialization Check]
DATA_EXISTS=false
if [[ -d "$REAL_STORAGE_PATH" ]] && [[ "$(ls -A "$REAL_STORAGE_PATH")" ]]; then DATA_EXISTS=true; fi
if [[ -d "$QUAY_BASE_HOME" ]] && [[ "$(ls -A "$QUAY_BASE_HOME")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Quay data found!"
    echo "=================================================================="
    echo " Locations detected:"
    echo "  - Data Storage : $QUAY_REAL_DATA_DIR"
    echo "  - Base Home    : $QUAY_BASE_HOME"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data, DB, logs)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > [Check] Verifying container status..."

        RUNNING_CTRS=$(podman ps --format "{{.Names}}" | grep -E "^(${QUAY_CONTAINER_NAME}|${PG_CONTAINER_NAME}|${REDIS_CONTAINER_NAME})$")

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

        ### Stop and remove existing containers
        podman rm -f "$QUAY_CONTAINER_NAME" "$PG_CONTAINER_NAME" "$REDIS_CONTAINER_NAME" 2>/dev/null || true

        echo "  > [Step 1] Cleaning Real Data..."
        if [[ -d "$QUAY_REAL_DATA_DIR" ]]; then rm -rf "${QUAY_REAL_DATA_DIR:?}"/*; fi

        echo "  > [Step 2] Cleaning Base Home (Config, Symlinks)..."
        if [[ -d "$QUAY_BASE_HOME" ]]; then rm -rf "${QUAY_BASE_HOME:?}"/*; fi

        echo "  > [Check] All directories initialized."
    else
        echo ""
        echo "  > [CANCEL] Installation aborted by user."
        exit 0
    fi
fi

### Create Directories
mkdir -p "$LOCAL_CONFIG_PATH"
mkdir -p "$REAL_STORAGE_PATH"
mkdir -p "$REAL_PG_PATH"
mkdir -p "$REAL_REDIS_PATH"

### Symbolic Link Logic
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    echo "  > Creating Symbolic Links..."
    ln -snf "$REAL_STORAGE_PATH" "$LINK_STORAGE_PATH"
    ln -snf "$REAL_PG_PATH" "$LINK_PG_PATH"
    ln -snf "$REAL_REDIS_PATH" "$LINK_REDIS_PATH"
fi

### ==============================================================================
### 5. Install Certificates & Configure Permissions
### ==============================================================================

echo ""
echo "Preparing SSL certificates..."

TARGET_CRT="${LOCAL_CONFIG_PATH}/ssl.cert"
TARGET_KEY="${LOCAL_CONFIG_PATH}/ssl.key"

cp "$SOURCE_CERT" "$TARGET_CRT"
cp "$SOURCE_KEY"  "$TARGET_KEY"

### Secure permissions for Root
chmod 644 "$TARGET_CRT"
chmod 600 "$TARGET_KEY"

### Grant READ access to the Quay container user (UID 1001) using ACL.
echo "  > Granting read permission to UID 1001 for SSL keys..."
setfacl -m u:1001:r "$TARGET_CRT"
setfacl -m u:1001:r "$TARGET_KEY"

echo "  > Certificates installed to: $LOCAL_CONFIG_PATH"

### ==============================================================================
### 6. Create Security Environment File (.env)
### ==============================================================================

echo ""
echo "Creating Secure Environment File..."
ENV_FILE="${QUAY_BASE_HOME}/quay-secrets.env"

cat <<EOF > "$ENV_FILE"
POSTGRESQL_USER=${PG_USER}
POSTGRESQL_PASSWORD=${PG_PASSWORD}
POSTGRESQL_DATABASE=${PG_DB_NAME}
POSTGRESQL_ADMIN_PASSWORD=${PG_ADMIN_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF

### Secure the env file
chmod 600 "$ENV_FILE"
echo "  > Created & Secured: $ENV_FILE"

### ==============================================================================
### 7. Component Deployment: Database & Redis
### ==============================================================================

echo ""
echo "Deploying Components..."

### 7.1 PostgreSQL Deployment
echo "  > Starting PostgreSQL..."
### Set permissions for Postgres user (UID 26)
setfacl -m u:26:-wx "$REAL_PG_PATH"

podman_pg_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$PG_CONTAINER_NAME"

    ### Resource Limits
    "--cpus" "${PG_CPU}"
    "--memory" "${PG_MEM}"

    ### Security: Use env-file instead of -e
    "--env-file" "$ENV_FILE"

    ### Use raw input for binding
    "-p" "${DB_PUBLISH_PORT}:5432"
    "--volume" "${REAL_PG_PATH}:/var/lib/pgsql/data:Z"
    "$PG_IMAGE"
)

### Remove existing if any
podman rm -f "$PG_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "PostgreSQL Command:"
echo "${podman_pg_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_pg_cmd[@]}"

echo "    ...Waiting for PostgreSQL to initialize (10s)..."
sleep 10
echo "    ...Ensuring pg_trgm extension exists..."

### [FIX] Use eval for complex string command execution
pg_exec_cmd="podman exec -it $PG_CONTAINER_NAME /bin/bash -c \"psql -U $PG_USER -d $PG_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'\""
echo "----------------------------------------------------------------"
echo "PostgreSQL Extension Command:"
echo "$pg_exec_cmd"
echo "----------------------------------------------------------------"
eval "$pg_exec_cmd"

### 7.2 Redis Deployment
echo "  > Starting Redis..."
podman_redis_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$REDIS_CONTAINER_NAME"

    ### Resource Limits
    "--cpus" "${REDIS_CPU}"
    "--memory" "${REDIS_MEM}"

    ### Security: Use env-file
    "--env-file" "$ENV_FILE"

    "-p" "${REDIS_PUBLISH_PORT}:6379"
    "$REDIS_IMAGE"
)

### Remove existing if any
podman rm -f "$REDIS_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Redis Command:"
echo "${podman_redis_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_redis_cmd[@]}"

### ==============================================================================
### 8. Construct Quay Configuration
### ==============================================================================

echo ""
echo "Generating Quay Configuration..."
CONFIG_FILE="${LOCAL_CONFIG_PATH}/config.yaml"

### Extract Port Numbers for Internal Config
DB_PORT_NUM=$(get_port_number "$DB_PUBLISH_PORT")
REDIS_PORT_NUM=$(get_port_number "$REDIS_PUBLISH_PORT")

### Generate Secrets
SECRET_KEY=$(uuidgen)
DB_SECRET_KEY=$(uuidgen)

### Create config.yaml
cat <<EOF > "$CONFIG_FILE"
SERVER_HOSTNAME: ${QUAY_HOST_NAME}
SETUP_COMPLETE: true

SUPER_USERS:
  - quayadmin

PREFERRED_URL_SCHEME: https

# Required Secrets
SECRET_KEY: ${SECRET_KEY}
DATABASE_SECRET_KEY: ${DB_SECRET_KEY}

# Database Settings
DB_URI: postgresql://${PG_USER}:${PG_PASSWORD}@${QUAY_HOST_NAME}:${DB_PORT_NUM}/${PG_DB_NAME}

CREATE_NAMESPACE_ON_PUSH: true

# Redis Settings
BUILDLOGS_REDIS:
  host: ${QUAY_HOST_NAME}
  port: ${REDIS_PORT_NUM}
  password: ${REDIS_PASSWORD}
USER_EVENTS_REDIS:
  host: ${QUAY_HOST_NAME}
  port: ${REDIS_PORT_NUM}
  password: ${REDIS_PASSWORD}

# Local Storage Settings
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - LocalStorage
    - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
DISTRIBUTED_STORAGE_PREFERENCE:
    - default

# Disable Mailing (For disconnected)
FEATURE_MAILING: false
EOF

### Secure config.yaml
chmod 600 "$CONFIG_FILE"

### [CRITICAL FIX] Grant read access to Quay container user (UID 1001)
setfacl -m u:1001:r "$CONFIG_FILE"

echo "  > Created & Secured: $CONFIG_FILE"

### ==============================================================================
### 9. Run Quay Container
### ==============================================================================

### Set permissions for Quay user (UID 1001) on storage
echo "Setting permissions for storage..."
setfacl -m u:1001:-wx "$REAL_STORAGE_PATH"

echo ""
echo "Constructing Quay container command..."

if podman ps -a --format "{{.Names}}" | grep -q "^${QUAY_CONTAINER_NAME}$"; then
    echo "  > Removing existing container..."
    podman rm -f "$QUAY_CONTAINER_NAME"
fi

### Constructing command
podman_quay_cmd=(
    "podman" "run" "-d" "--rm"
    "--name" "$QUAY_CONTAINER_NAME"

    ### Resource Limits
    "--cpus" "${QUAY_CPU}"
    "--memory" "${QUAY_MEM}"

    ### Port Mapping (Supports IP:Port)
    "-p" "${QUAY_PUBLISH_HTTPS}:8443"
    "-p" "${QUAY_PUBLISH_HTTP}:8080"

    ### Volume Arguments
    "--volume" "${LOCAL_CONFIG_PATH}:/conf/stack:Z"
    "--volume" "${REAL_STORAGE_PATH}:/datastorage:Z"

    ### Image Name
    "$QUAY_IMAGE"
)

echo "----------------------------------------------------------------"
echo "Quay Command:"
echo "${podman_quay_cmd[*]}"
echo "----------------------------------------------------------------"

"${podman_quay_cmd[@]}"

echo ""
echo "Red Hat Quay container started."
echo "Access UI at: https://${QUAY_HOST_NAME}:$(get_port_number "$QUAY_PUBLISH_HTTPS")"


### ==============================================================================
### 10. Configure Podman Trust (Host Trust Store)
### ==============================================================================
echo ""
echo "Configuring Podman Trust for Hostname..."

### Directory where Podman looks for registries certificates
PODMAN_CERT_DIR="/etc/containers/certs.d/${QUAY_HOST_NAME}"

if [[ ! -d "$PODMAN_CERT_DIR" ]]; then
    mkdir -p "$PODMAN_CERT_DIR"
    cp "$SOURCE_CERT" "${PODMAN_CERT_DIR}/ca.crt"
    echo "  > Certificate copied to ${PODMAN_CERT_DIR}/ca.crt"
    echo "  > You can now run 'podman login ${QUAY_HOST_NAME}' without --tls-verify=false"
else
    echo "  > Trust directory $PODMAN_CERT_DIR already exists."
    cp "$SOURCE_CERT" "${PODMAN_CERT_DIR}/ca.crt"
    echo "  > Certificate updated in trust store."
fi


### ==============================================================================
### 11. Firewall Configuration
### ==============================================================================

echo ""
echo "Configuring Firewall..."

FW_HTTP=$(get_port_number "$QUAY_PUBLISH_HTTP")
FW_HTTPS=$(get_port_number "$QUAY_PUBLISH_HTTPS")
FW_DB=$(get_port_number "$DB_PUBLISH_PORT")
FW_REDIS=$(get_port_number "$REDIS_PUBLISH_PORT")

FIREWALL_PORTS=("$FW_HTTP" "$FW_HTTPS" "$FW_DB" "$FW_REDIS")

for PORT in "${FIREWALL_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "5432" ]]; then
            semanage port -a -t postgresql_port_t -p tcp ${PORT} 2>/dev/null || true
        elif [[ "$PORT" == "6379" ]]; then
             semanage port -a -t redis_port_t -p tcp ${PORT} 2>/dev/null || true
        else
             semanage port -a -t http_port_t -p tcp ${PORT} 2>/dev/null || true
        fi

        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null
echo "Firewall rules updated."

### ==============================================================================
### 12. Generate 'start-quay.sh' (Standalone Startup Script)
### ==============================================================================

echo ""
echo "Generating standalone startup script: start-quay.sh ..."

START_SCRIPT="${QUAY_BASE_HOME}/start-quay.sh"

### Use env file variable in script
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
# ============================================================================
# Quay Standalone Startup Script
# Generated by install script on $(date)
# ============================================================================

ENV_FILE="${ENV_FILE}"

echo "Stopping and removing existing containers..."
podman rm -f ${PG_CONTAINER_NAME} ${REDIS_CONTAINER_NAME} ${QUAY_CONTAINER_NAME} 2>/dev/null || true

echo "Starting PostgreSQL..."
podman run -d --rm \\
    --name ${PG_CONTAINER_NAME} \\
    --cpus ${PG_CPU} \\
    --memory ${PG_MEM} \\
    --env-file "\$ENV_FILE" \\
    -p ${DB_PUBLISH_PORT}:5432 \\
    --volume ${REAL_PG_PATH}:/var/lib/pgsql/data:Z \\
    ${PG_IMAGE}

echo "Waiting for PostgreSQL (5s)..."
sleep 5

echo "Starting Redis..."
podman run -d --rm \\
    --name ${REDIS_CONTAINER_NAME} \\
    --cpus ${REDIS_CPU} \\
    --memory ${REDIS_MEM} \\
    --env-file "\$ENV_FILE" \\
    -p ${REDIS_PUBLISH_PORT}:6379 \\
    ${REDIS_IMAGE}

echo "Starting Quay..."
podman run -d --rm \\
    --name ${QUAY_CONTAINER_NAME} \\
    --cpus ${QUAY_CPU} \\
    --memory ${QUAY_MEM} \\
    -p ${QUAY_PUBLISH_HTTPS}:8443 \\
    -p ${QUAY_PUBLISH_HTTP}:8080 \\
    --volume ${LOCAL_CONFIG_PATH}:/conf/stack:Z \\
    --volume ${REAL_STORAGE_PATH}:/datastorage:Z \\
    ${QUAY_IMAGE}

echo "All services started."
EOF

chmod 700 "$START_SCRIPT"
echo "  > Script created at: $START_SCRIPT"

### ==============================================================================
### 13. Generate 'start-quay-config.sh' (Config Tool)
### ==============================================================================

echo ""
echo "Generating Config Editor script: start-quay-config.sh ..."

EDITOR_SCRIPT="${QUAY_BASE_HOME}/start-quay-config.sh"
EDITOR_PORT="8080"
EDITOR_CONTAINER_NAME="quay-config"

### We use variables from the main installer script for the header of the generated script.
### Internal logic variables (starting with $) are escaped with backslash.

cat <<EOF > "$EDITOR_SCRIPT"
#!/bin/bash

### ==============================================================================
### Quay Config Editor Launch Script
### Description: Safely stops running Quay instances to allow Config Editor usage.
### ==============================================================================

### Colors
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\${YELLOW}[INFO] Preparing to start Quay Config Editor...\${NC}"

### ------------------------------------------------------------------------------
### 1. Detect Running Instances
### ------------------------------------------------------------------------------
IS_ACTIVE=false
RUNNING_SOURCE=""

# Check Systemd Service
if systemctl list-units --full -all | grep -Fq "container-${QUAY_CONTAINER_NAME}.service"; then
    if systemctl is-active --quiet "container-${QUAY_CONTAINER_NAME}.service"; then
        IS_ACTIVE=true
        RUNNING_SOURCE="Systemd Service (container-${QUAY_CONTAINER_NAME}.service)"
    fi
fi

# Check Podman Container (if systemd wasn't found or active)
if [ "\$IS_ACTIVE" = false ] && [ "\$(podman ps -q -f name=^/${QUAY_CONTAINER_NAME}\$)" ]; then
    IS_ACTIVE=true
    RUNNING_SOURCE="Podman Container ($QUAY_CONTAINER_NAME)"
fi

### ------------------------------------------------------------------------------
### 2. User Confirmation (If Quay is running)
### ------------------------------------------------------------------------------
if [ "\$IS_ACTIVE" = true ]; then
    echo ""
    echo -e "\${RED}==================================================================\${NC}"
    echo -e "\${RED} [WARNING] Quay is currently running via: \$RUNNING_SOURCE\${NC}"
    echo -e "\${RED}==================================================================\${NC}"
    echo -e " The Config Editor cannot run while the main Quay container is active"
    echo -e " because they use the same database and configuration files."
    echo ""

    # Prompt user
    read -p " Do you want to STOP Quay and start the Config Editor? [y/N]: " confirm

    if [[ ! "\$confirm" =~ ^[Yy]\$ ]]; then
        echo ""
        echo -e "\${GREEN}[CANCEL] Operation canceled by user. Quay remains running.\${NC}"
        exit 0
    fi
    echo ""
fi

### ------------------------------------------------------------------------------
### 3. Stop Logic (Execute only if confirmed or not running)
### ------------------------------------------------------------------------------

# Stop Systemd Service if it exists
if systemctl list-units --full -all | grep -Fq "container-${QUAY_CONTAINER_NAME}.service"; then
    if systemctl is-active --quiet "container-${QUAY_CONTAINER_NAME}.service"; then
        echo -e "\${YELLOW}[ACTION] Stopping Systemd service...\${NC}"
        systemctl stop "container-${QUAY_CONTAINER_NAME}.service"
        echo -e "\${GREEN}[OK] Service stopped.\${NC}"
    fi
fi

# Stop/Remove Podman Container if it exists
if [ "\$(podman ps -aq -f name=^/${QUAY_CONTAINER_NAME}\$)" ]; then
    echo -e "\${YELLOW}[ACTION] Removing existing Quay container...\${NC}"
    podman rm -f "$QUAY_CONTAINER_NAME" > /dev/null
    echo -e "\${GREEN}[OK] Container removed.\${NC}"
fi

### ------------------------------------------------------------------------------
### 4. Run Quay Config Editor
### ------------------------------------------------------------------------------
echo ""
echo -e "\${YELLOW}[INFO] Starting Config Editor Container...\${NC}"
echo -e "------------------------------------------------------------"
echo -e " Access URL : http://$QUAY_HOST_NAME:$EDITOR_PORT"
echo -e " Username   : (Check the logs below)"
echo -e " Password   : secret"
echo -e "------------------------------------------------------------"
echo -e "Press Ctrl+C to stop the editor."

podman run --rm -it --name "$EDITOR_CONTAINER_NAME" \\
  -p $EDITOR_PORT:8080 \\
  -v $LOCAL_CONFIG_PATH:/conf/stack:Z \\
  $QUAY_IMAGE config secret

echo ""
echo -e "\${GREEN}[DONE] Config Editor exited.\${NC}"
echo -e "\${YELLOW}[NOTE] Run 'systemctl start container-${QUAY_CONTAINER_NAME}' to restart Quay.\${NC}"
EOF

chmod 700 "$EDITOR_SCRIPT"
echo "  > Script created at: $EDITOR_SCRIPT"

### ==============================================================================
### 14. Register as RHEL 9 Systemd Service (Auto-Start)
### ==============================================================================

echo ""
echo "Configuring Systemd for Auto-Start..."

SYSTEMD_DIR="/etc/systemd/system"

### Generate Unit Files
cd "$SYSTEMD_DIR" || exit

echo "  > Generating Service: container-${PG_CONTAINER_NAME}.service"
podman generate systemd --new --files --name "$PG_CONTAINER_NAME" >/dev/null

echo "  > Generating Service: container-${REDIS_CONTAINER_NAME}.service"
podman generate systemd --new --files --name "$REDIS_CONTAINER_NAME" >/dev/null

echo "  > Generating Service: container-${QUAY_CONTAINER_NAME}.service"
podman generate systemd --new --files --name "$QUAY_CONTAINER_NAME" >/dev/null

### Add dependencies to Quay service (Wait for PG & Redis)
QUAY_SVC_FILE="container-${QUAY_CONTAINER_NAME}.service"
if [[ -f "$QUAY_SVC_FILE" ]]; then
    ### Add Requires/After lines to [Unit] section if not present
    if ! grep -q "Requires=container-${PG_CONTAINER_NAME}.service" "$QUAY_SVC_FILE"; then
         sed -i "/^After=/ s/$/ container-${PG_CONTAINER_NAME}.service container-${REDIS_CONTAINER_NAME}.service/" "$QUAY_SVC_FILE"
         sed -i "/^After=/a Requires=container-${PG_CONTAINER_NAME}.service container-${REDIS_CONTAINER_NAME}.service" "$QUAY_SVC_FILE"
    fi
fi

### Reload and Enable
systemctl daemon-reload
systemctl enable "container-${PG_CONTAINER_NAME}"
systemctl enable "container-${REDIS_CONTAINER_NAME}"
systemctl enable "container-${QUAY_CONTAINER_NAME}"

echo ""
echo "----------------------------------------------------------------"
echo " [SUCCESS] Installation & Service Registration Complete"
echo "----------------------------------------------------------------"
echo " 1. Manual Start Script : $START_SCRIPT"
echo " 2. Config Editor Tool  : $EDITOR_SCRIPT"
echo " 3. Systemd Services    : Enabled (Starts on boot)"
echo ""
echo " IMPORTANT: Currently, containers are running via 'podman run'."
echo " To switch to Systemd management immediately, run:"
echo "   podman stop ${PG_CONTAINER_NAME} ${REDIS_CONTAINER_NAME} ${QUAY_CONTAINER_NAME}"
echo "   systemctl start container-${PG_CONTAINER_NAME} container-${REDIS_CONTAINER_NAME} container-${QUAY_CONTAINER_NAME}"
echo "----------------------------------------------------------------"
echo ""