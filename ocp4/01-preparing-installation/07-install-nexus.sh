#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
NEXUS_HOST_NAME="registry.cloudpang.lan"
NEXUS_BASE_HOME="/opt/sonatype/nexus"

NEXUS_IMAGE="docker.io/sonatype/nexus3:latest"
NEXUS_CONTAINER_NAME="nexus"

### 2. Certificate Configuration (Flexible)
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
NEXUS_CUSTOM_CERT=""
NEXUS_CUSTOM_KEY=""

### 3. Data Directory
NEXUS_REAL_DATA_DIR="/data/nexus-data"

### 4. Port Settings
### Defined ports will be exposed. Leave empty to disable.
NEXUS_PUBLISH_HTTP=""
NEXUS_PUBLISH_HTTPS=""
NEXUS_PUBLISH_DOCKER_01=""
NEXUS_PUBLISH_DOCKER_02=""

######################################################################################
###                                                                                ###
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
###                                                                                ###
######################################################################################

### ==============================================================================
### 1. Port Configuration
### ==============================================================================

### Default values for External Ports
### Internal Container Ports are fixed: HTTP=8081, HTTPS=8443
NEXUS_PUBLISH_HTTP="${NEXUS_PUBLISH_HTTP:-8081}"
NEXUS_PUBLISH_HTTPS="${NEXUS_PUBLISH_HTTPS:-8443}"
NEXUS_PUBLISH_DOCKER_01="${NEXUS_PUBLISH_DOCKER_01:-5000}"
NEXUS_PUBLISH_DOCKER_02="${NEXUS_PUBLISH_DOCKER_02:-5001}"

### ==============================================================================
### 2. Certificate Resolution Logic
### ==============================================================================

echo "Resolving certificate paths..."

if [[ -n "$NEXUS_CUSTOM_CERT" ]]; then
    NEXUS_CERT="$NEXUS_CUSTOM_CERT"
    echo "  > Using custom certificate path: $NEXUS_CERT"
else
    NEXUS_CERT="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt"
    echo "  > Using default certificate path: $NEXUS_CERT"
fi

if [[ -n "$NEXUS_CUSTOM_KEY" ]]; then
    NEXUS_KEY="$NEXUS_CUSTOM_KEY"
    echo "  > Using custom key path: $NEXUS_KEY"
else
    NEXUS_KEY="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key"
    echo "  > Using default key path: $NEXUS_KEY"
fi

if [[ ! -f "$NEXUS_CERT" ]]; then
    echo "Error: Certificate file not found at: $NEXUS_CERT"
    exit 1
fi
if [[ ! -f "$NEXUS_KEY" ]]; then
    echo "Error: Key file not found at: $NEXUS_KEY"
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

### --- Process HTTP Port (Maps to Internal 8081) ---
if [[ -n "$NEXUS_PUBLISH_HTTP" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTP")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTP}:8081")
    FIREWALL_PORTS+=("$P_NUM")
fi

### --- Process HTTPS Port (Maps to Internal 8443) ---
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTPS")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTPS}:8443")
    FIREWALL_PORTS+=("$P_NUM")
fi

### --- Process Docker Port 01 (Maps 1:1) ---
if [[ -n "$NEXUS_PUBLISH_DOCKER_01" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_01")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_01}:${P_NUM}")
    FIREWALL_PORTS+=("$P_NUM")
fi

### --- Process Docker Port 02 (Maps 1:1) ---
if [[ -n "$NEXUS_PUBLISH_DOCKER_02" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_02")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_02}:${P_NUM}")
    FIREWALL_PORTS+=("$P_NUM")
fi

### ==============================================================================
### 3. Preparation (Cleanup)
### ==============================================================================

if [[ ! -d "$NEXUS_BASE_HOME" ]]; then
    mkdir -p "$NEXUS_BASE_HOME"
fi

### ==============================================================================
### 4. Directory Setup (UID 200)
### ==============================================================================

echo ""
echo "Configuring Directories..."

### Create SSL config directory
mkdir -p "${NEXUS_BASE_HOME}/nexus-etc-ssl"
echo "  - Config/SSL located at: ${NEXUS_BASE_HOME}/nexus-etc-ssl"

### Standard Internal Path (Symbolic Link Target)
LINK_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"

### Determine Real Physical Paths & Create Links
if [[ -n "$NEXUS_REAL_DATA_DIR" ]] && [[ "$NEXUS_REAL_DATA_DIR" != "$NEXUS_BASE_HOME" ]]; then
    REAL_DATA_PATH="${NEXUS_REAL_DATA_DIR}"
    echo "  - Using custom storage at: $NEXUS_REAL_DATA_DIR"

    mkdir -p "$REAL_DATA_PATH"

    echo "  - Updating symlinks in ${NEXUS_BASE_HOME}..."

    if [[ -d "$LINK_DATA_PATH" ]] && [[ ! -L "$LINK_DATA_PATH" ]]; then
        echo "    [Warning] Removing existing directory '$LINK_DATA_PATH' to replace with symlink."
        rm -rf "$LINK_DATA_PATH"
    fi
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"

else
    REAL_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
    echo "  - Using standard storage at: $NEXUS_BASE_HOME"
    mkdir -p "$REAL_DATA_PATH"
fi

### Nexus Specific: Prepare etc directory for nexus.properties
mkdir -p "${REAL_DATA_PATH}/etc"

### Nexus Specific: Set Permissions (UID 200 for Nexus)
echo "  - Setting permissions (UID 200:200)..."
chown -R 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl"
chown -R 200:200 "${REAL_DATA_PATH}"
if [[ -L "$LINK_DATA_PATH" ]]; then
    chown -h 200:200 "$LINK_DATA_PATH"
fi

echo "    > Data Path: $(ls -ld "$LINK_DATA_PATH")"

### ==============================================================================
### 5. Install Certificates (PKCS12 -> JKS)
### ==============================================================================

echo ""
echo "Generating SSL keystore..."

JKS_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl/keystore.jks"
PKCS12_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12"

### Convert CRT/KEY to PKCS12
openssl pkcs12 -export -in "$NEXUS_CERT" -inkey "$NEXUS_KEY" \
  -out "$PKCS12_PATH" \
  -name nexus -passout pass:password

chown 200:200 "$PKCS12_PATH"

### Convert PKCS12 to JKS using the container's keytool (Ephemeral container)
podman run --rm \
  -v "${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z" \
  --entrypoint keytool \
  "$NEXUS_IMAGE" \
    -importkeystore \
    -srckeystore /opt/sonatype/nexus/etc/ssl/nexus.p12 -srcstoretype PKCS12 \
    -destkeystore /opt/sonatype/nexus/etc/ssl/keystore.jks -deststoretype JKS \
    -srcstorepass password -deststorepass password > /dev/null 2>&1

chown 200:200 "$JKS_PATH"
echo "  > Keystore created at: $JKS_PATH"

### ==============================================================================
### 6. Construct Nexus Properties
### ==============================================================================

echo "Generating nexus.properties..."

### Determine enabled Jetty modules
JETTY_XML_LIST="\${jetty.etc}/jetty-requestlog.xml"

### Always enable HTTP (Standard)
JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty.xml"

### Enable HTTPS if port is configured
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty-https.xml"
fi

PROPERTY_FILE="${REAL_DATA_PATH}/etc/nexus.properties"

cat <<EOF > "$PROPERTY_FILE"
### Nexus runtime arguments
nexus-args=${JETTY_XML_LIST}

### Standard Application Port (Internal 8081)
application-port=8081

### SSL Application Port (Internal 8443)
application-port-ssl=8443

### SSL Keystore settings
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF

chown 200:200 "$PROPERTY_FILE"

### ==============================================================================
### 7. Run Nexus Container
### ==============================================================================

echo ""
echo "Constructing Nexus container command..."

### Clean up existing container if it exists
if podman ps -a --format "{{.Names}}" | grep -q "^${NEXUS_CONTAINER_NAME}$"; then
    echo "  > Found existing container '${NEXUS_CONTAINER_NAME}'. Removing it..."
    podman rm -f "$NEXUS_CONTAINER_NAME"
fi

### Build the command array
PODMAN_ARGS=(podman run -d)
PODMAN_ARGS+=("${PODMAN_PORT_ARGS[@]}")
PODMAN_ARGS+=(--restart always)
PODMAN_ARGS+=(--name "$NEXUS_CONTAINER_NAME")
PODMAN_ARGS+=(--volume "${REAL_DATA_PATH}:/nexus-data:Z")
PODMAN_ARGS+=(--volume "${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z")
PODMAN_ARGS+=("$NEXUS_IMAGE")

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
echo "Nexus container started."
echo "----------------------------------------------------------------"
echo "[Verification] Actual command executed by Podman:"
echo ""
podman inspect "$NEXUS_CONTAINER_NAME" --format '{{range .Config.CreateCommand}}{{.}} {{end}}'
echo ""
echo "----------------------------------------------------------------"
echo ""
echo "Wait for initialization (2-5 mins)."
echo "Initial admin password file: ${LINK_DATA_PATH}/admin.password"

### ==============================================================================
### 8. Configure Firewall and SELinux
### ==============================================================================

echo ""
echo "Configuring SELinux and Firewall..."

for PORT in "${FIREWALL_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        echo "Opening port $PORT/tcp..."
        semanage port -a -t http_port_t -p tcp ${PORT} 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp
    fi
done

firewall-cmd --reload
echo ""