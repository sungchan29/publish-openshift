#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
NEXUS_HOST_NAME="registry.cloudpang.lan"
NEXUS_BASE_HOME="/opt/nexus"

NEXUS_IMAGE="docker.io/sonatype/nexus3:latest"
NEXUS_CONTAINER_NAME="nexus"

### 2. Certificate Configuration (Flexible)
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
NEXUS_CUSTOM_CERT=""
NEXUS_CUSTOM_KEY=""

### 3. Data Directory
NEXUS_REAL_DATA_DIR="/data/nexus"

### 4. Port Settings
### [Rule 1] At least one of HTTP or HTTPS must be set.
### [Rule 2] DOCKER_01 is MANDATORY. DOCKER_02 is Optional.
### Leave empty ("") to disable specific access.
NEXUS_PUBLISH_HTTP=""
NEXUS_PUBLISH_HTTPS="172.16.120.28:8443"
NEXUS_PUBLISH_DOCKER_01="172.16.120.28:5000"
NEXUS_PUBLISH_DOCKER_02="172.16.120.28:5001"

### 5. Resource Limits
### Nexus is Java-based and memory intensive.
### Recommended: CPU="4" (4 cores), MEM="4g" (4GB or more)
NEXUS_CPU="4"
NEXUS_MEM="4g"

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Configuration Validation
### ==============================================================================

echo "Validating configuration..."

### Check Rule 1: HTTP or HTTPS
if [[ -z "$NEXUS_PUBLISH_HTTP" ]] && [[ -z "$NEXUS_PUBLISH_HTTPS" ]]; then
    echo "[ERROR] Invalid Configuration: At least one of 'NEXUS_PUBLISH_HTTP' or 'NEXUS_PUBLISH_HTTPS' must be set."
    exit 1
fi

### Check Rule 2: Docker Port 01
if [[ -z "$NEXUS_PUBLISH_DOCKER_01" ]]; then
    echo "[ERROR] Invalid Configuration: 'NEXUS_PUBLISH_DOCKER_01' is MANDATORY."
    exit 1
fi

echo "  > Port Configuration Validated."

### ==============================================================================
### 2. Certificate Resolution Logic (Enforce Cert Existence if HTTPS is set)
### ==============================================================================

if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    echo "Resolving certificate paths..."

    if [[ -n "$NEXUS_CUSTOM_CERT" ]]; then
        NEXUS_CERT="$NEXUS_CUSTOM_CERT"
    else
        NEXUS_CERT="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt"
    fi

    if [[ -n "$NEXUS_CUSTOM_KEY" ]]; then
        NEXUS_KEY="$NEXUS_CUSTOM_KEY"
    else
        NEXUS_KEY="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key"
    fi

    ### [CRITICAL CHECK] If HTTPS is enabled, Cert files MUST exist.
    if [[ ! -f "$NEXUS_CERT" ]] || [[ ! -f "$NEXUS_KEY" ]]; then
        echo ""
        echo "=================================================================="
        echo " [ERROR] HTTPS is enabled but certificate files are missing!"
        echo "=================================================================="
        echo " Checked Paths:"
        echo "  - Certificate : $NEXUS_CERT"
        echo "  - Private Key : $NEXUS_KEY"
        echo "=================================================================="
        echo " Please ensure the certificate files exist or disable HTTPS."
        exit 1
    fi
    echo "  > Certificate found: $NEXUS_CERT"
else
    echo "HTTPS disabled. Skipping certificate resolution."
fi

### ==============================================================================
### Helper: Parse Ports & Build Arguments
### ==============================================================================

get_port_number() {
    local input=$1
    echo "${input##*:}"
}

PODMAN_PORT_ARGS=()
FIREWALL_PORTS=()

### HTTP (Dynamic)
if [[ -n "$NEXUS_PUBLISH_HTTP" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTP")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTP}:8081")
    FIREWALL_PORTS+=("$P_NUM")
    echo "  > HTTP Enabled  : $NEXUS_PUBLISH_HTTP"
fi

### HTTPS (Dynamic)
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTPS")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTPS}:8443")
    FIREWALL_PORTS+=("$P_NUM")
    echo "  > HTTPS Enabled : $NEXUS_PUBLISH_HTTPS"
fi

### Docker 01 (Mandatory)
P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_01")
PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_01}:${P_NUM}")
FIREWALL_PORTS+=("$P_NUM")
echo "  > Docker 01     : $NEXUS_PUBLISH_DOCKER_01"

### Docker 02 (Optional)
if [[ -n "$NEXUS_PUBLISH_DOCKER_02" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_02")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_02}:${P_NUM}")
    FIREWALL_PORTS+=("$P_NUM")
    echo "  > Docker 02     : $NEXUS_PUBLISH_DOCKER_02"
fi

### ==============================================================================
### 3. Directory Setup & Interactive Initialization
### ==============================================================================

### Define Location Variables
### 1. Base Home Paths (SSL Storage for Nexus)
LOCAL_SSL_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl"

### 2. Real Data Paths (Main Data)
if [[ -n "$NEXUS_REAL_DATA_DIR" ]] && [[ "$NEXUS_REAL_DATA_DIR" != "$NEXUS_BASE_HOME" ]]; then
    REAL_DATA_PATH="${NEXUS_REAL_DATA_DIR}"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
    IS_SPLIT_STORAGE=false
fi

echo ""
echo "Configuring Directories..."
echo "  [Base Home] SSL Path    : $LOCAL_SSL_PATH"
echo "  [Real Data] Data Path   : $REAL_DATA_PATH"

### [Interactive Initialization Check]
DATA_EXISTS=false
if [[ -d "$REAL_DATA_PATH" ]] && [[ "$(ls -A "$REAL_DATA_PATH")" ]]; then DATA_EXISTS=true; fi
if [[ -d "$NEXUS_BASE_HOME" ]] && [[ "$(ls -A "$NEXUS_BASE_HOME")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Nexus data found!"
    echo "=================================================================="
    echo " Locations detected:"
    echo "  - Data Storage : $NEXUS_REAL_DATA_DIR"
    echo "  - Base Home    : $NEXUS_BASE_HOME"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data, keystores, and configs)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        ### -----------------------------------------------------------
        ### [Check] Check if containers are running and EXIT
        ### -----------------------------------------------------------
        echo "  > [Check] Verifying container status..."

        ### Check running containers matching our names
        RUNNING_CTRS=$(podman ps --format "{{.Names}}" | grep -E "^(${NEXUS_CONTAINER_NAME})$")

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

        echo "  > [Step 1] Cleaning Real Data..."

        ### Remove STOPPED containers (Safe cleanup)
        podman rm "$NEXUS_CONTAINER_NAME" 2>/dev/null || true

        if [[ -d "$REAL_DATA_PATH" ]]; then rm -rf "${REAL_DATA_PATH:?}"/*; fi

        echo "  > [Step 2] Cleaning Base Home (SSL, Symlinks)..."
        ### Clean everything in Base Home
        if [[ -d "$NEXUS_BASE_HOME" ]]; then
             rm -rf "${NEXUS_BASE_HOME:?}"/*
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
mkdir -p "$LOCAL_SSL_PATH"
mkdir -p "$REAL_DATA_PATH"
mkdir -p "${REAL_DATA_PATH}/etc"

### Symbolic Link Logic (Optional: Links Real path to Base Home for visibility)
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    LINK_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"

    ### Link Data
    if [[ -d "$LINK_DATA_PATH" ]] && [[ ! -L "$LINK_DATA_PATH" ]]; then rm -rf "$LINK_DATA_PATH"; fi
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
else
    LINK_DATA_PATH="$REAL_DATA_PATH"
fi

### Permissions
chown -R 200:200 "${NEXUS_BASE_HOME}"
chown -R 200:200 "${REAL_DATA_PATH}"
[[ -L "$LINK_DATA_PATH" ]] && chown -h 200:200 "$LINK_DATA_PATH"

### ==============================================================================
### 4. Install Certificates (Keytool) - Only if HTTPS enabled
### ==============================================================================

echo ""
JKS_PATH="${LOCAL_SSL_PATH}/keystore.jks"
PKCS12_PATH="${LOCAL_SSL_PATH}/nexus.p12"

if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    echo "Generating SSL keystore..."

    ### Only generate if not exists
    if [[ ! -f "$JKS_PATH" ]]; then
        ### Convert CRT+KEY to PKCS12
        openssl pkcs12 -export -in "$NEXUS_CERT" -inkey "$NEXUS_KEY" \
          -out "$PKCS12_PATH" -name nexus -passout pass:password

        chown 200:200 "$PKCS12_PATH"

        ### Use Podman to run Keytool (Java) to convert PKCS12 to JKS
        keytool_cmd=(
            "podman" "run" "--rm"
            "-v" "${LOCAL_SSL_PATH}:/opt/sonatype/nexus/etc/ssl:Z"
            "--entrypoint" "keytool"
            "$NEXUS_IMAGE"
            "-importkeystore"
            "-srckeystore" "/opt/sonatype/nexus/etc/ssl/nexus.p12" "-srcstoretype" "PKCS12"
            "-destkeystore" "/opt/sonatype/nexus/etc/ssl/keystore.jks" "-deststoretype" "JKS"
            "-srcstorepass" "password" "-deststorepass" "password"
        )

        echo "----------------------------------------------------------------"
        echo "Keytool Import Command:"
        echo "${keytool_cmd[*]}"
        echo "----------------------------------------------------------------"

        ### Execute command (silence output unless error)
        "${keytool_cmd[@]}" > /dev/null 2>&1

        chown 200:200 "$JKS_PATH"
        echo "  > Keystore created at: $JKS_PATH"
    else
        echo "  > Keystore already exists. Skipping generation."
    fi
else
    echo "HTTPS disabled. Skipping Keystore generation."
fi

### ==============================================================================
### 5. Construct Nexus Properties
### ==============================================================================

### Base Jetty config
JETTY_XML_LIST="\${jetty.etc}/jetty-requestlog.xml,\${jetty.etc}/jetty.xml"

### Add HTTPS config if enabled
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty-https.xml"
fi

PROPERTY_FILE="${REAL_DATA_PATH}/etc/nexus.properties"

cat <<EOF > "$PROPERTY_FILE"
nexus-args=${JETTY_XML_LIST}
application-port=8081
application-port-ssl=8443
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF
chown 200:200 "$PROPERTY_FILE"

### ==============================================================================
### 6. Run Nexus Container
### ==============================================================================

echo ""
echo "Constructing Nexus container command..."

### Constructing command using Single Bash Array Block
podman_cmd=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$NEXUS_CONTAINER_NAME"

    ### Resource Limits
    "--cpus" "${NEXUS_CPU}"
    "--memory" "${NEXUS_MEM}"

    ### Volume Arguments (2 Distinct Volumes)
    ### 1. Main Data
    "--volume" "${REAL_DATA_PATH}:/nexus-data:Z"
    ### 2. SSL Store (Mounted to internal ssl path)
    "--volume" "${LOCAL_SSL_PATH}:/opt/sonatype/nexus/etc/ssl:Z"

    ### Port Arguments (Expanded from array)
    "${PODMAN_PORT_ARGS[@]}"

    ### Image Name
    "$NEXUS_IMAGE"
)

### Remove existing container (Force remove to ensure clean slate for RUN)
podman rm -f "$NEXUS_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Command to be executed:"
echo "${podman_cmd[*]}"
echo "----------------------------------------------------------------"

### Execute the array
"${podman_cmd[@]}"

echo ""
echo "Nexus container started."
echo "Wait for initialization (2-5 mins)."
echo "Initial admin password file: ${LINK_DATA_PATH}/admin.password"

### ==============================================================================
### 7. Firewall
### ==============================================================================

echo ""
echo "Configuring Firewall..."
for PORT in "${FIREWALL_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        semanage port -a -t http_port_t -p tcp ${PORT} 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp
    fi
done
firewall-cmd --reload
echo ""

### ==============================================================================
### 8. Generate 'start-nexus.sh' (Standalone Startup Script)
### ==============================================================================

echo "Generating standalone startup script: start-nexus.sh ..."

START_SCRIPT="${NEXUS_BASE_HOME}/start-nexus.sh"

### Note: We inject ${PODMAN_PORT_ARGS[*]} directly into the script.
### This creates a static script with the exact ports used during installation.
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
# ============================================================================
# Nexus Standalone Startup Script
# Generated by install script on $(date)
# ============================================================================

echo "Stopping and removing existing container..."
podman rm -f ${NEXUS_CONTAINER_NAME} 2>/dev/null || true

echo "Starting Nexus..."
podman run -d \\
    --restart always \\
    --name ${NEXUS_CONTAINER_NAME} \\
    --cpus ${NEXUS_CPU} \\
    --memory ${NEXUS_MEM} \\
    --volume ${REAL_DATA_PATH}:/nexus-data:Z \\
    --volume ${LOCAL_SSL_PATH}:/opt/sonatype/nexus/etc/ssl:Z \\
    ${PODMAN_PORT_ARGS[*]} \\
    ${NEXUS_IMAGE}

echo "Nexus started."
EOF

chmod +x "$START_SCRIPT"
echo "  > Script created at: $START_SCRIPT"
echo "  > You can use this script to manually restart Nexus later."

### ==============================================================================
### 9. Register as RHEL 9 Systemd Service (Auto-Start)
### ==============================================================================

echo ""
echo "Configuring Systemd for Auto-Start..."

SYSTEMD_DIR="/etc/systemd/system"

### Generate Unit Files
cd "$SYSTEMD_DIR" || exit

echo "  > Generating Service: container-${NEXUS_CONTAINER_NAME}.service"
### Generate service file (restart policy handled by systemd, container removal handled by service wrapper)
podman generate systemd --new --files --name "$NEXUS_CONTAINER_NAME" >/dev/null

### Reload and Enable
systemctl daemon-reload
systemctl enable "container-${NEXUS_CONTAINER_NAME}"

echo ""
echo "----------------------------------------------------------------"
echo " [SUCCESS] Installation & Service Registration Complete"
echo "----------------------------------------------------------------"
echo " 1. Manual Start Script : $START_SCRIPT"
echo " 2. Systemd Services    : Enabled (Starts on boot)"
echo ""
echo " IMPORTANT: Currently, Nexus is running via 'podman run'."
echo " To switch to Systemd management immediately, run:"
echo "   podman stop ${NEXUS_CONTAINER_NAME}"
echo "   systemctl start container-${NEXUS_CONTAINER_NAME}"
echo "----------------------------------------------------------------"
echo ""