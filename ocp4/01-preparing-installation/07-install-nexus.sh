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
NEXUS_PUBLISH_HTTP=""
NEXUS_PUBLISH_HTTPS=""
NEXUS_PUBLISH_DOCKER_01=""
NEXUS_PUBLISH_DOCKER_02=""

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### ==============================================================================
### 1. Port Configuration
### ==============================================================================

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
else
    NEXUS_CERT="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt"
fi

if [[ -n "$NEXUS_CUSTOM_KEY" ]]; then
    NEXUS_KEY="$NEXUS_CUSTOM_KEY"
else
    NEXUS_KEY="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key"
fi

if [[ ! -f "$NEXUS_CERT" ]] || [[ ! -f "$NEXUS_KEY" ]]; then
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

# HTTP
if [[ -n "$NEXUS_PUBLISH_HTTP" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTP")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTP}:8081")
    FIREWALL_PORTS+=("$P_NUM")
fi
# HTTPS
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_HTTPS")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_HTTPS}:8443")
    FIREWALL_PORTS+=("$P_NUM")
fi
# Docker Registry Ports
if [[ -n "$NEXUS_PUBLISH_DOCKER_01" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_01")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_01}:${P_NUM}")
    FIREWALL_PORTS+=("$P_NUM")
fi
if [[ -n "$NEXUS_PUBLISH_DOCKER_02" ]]; then
    P_NUM=$(get_port_number "$NEXUS_PUBLISH_DOCKER_02")
    PODMAN_PORT_ARGS+=("-p" "${NEXUS_PUBLISH_DOCKER_02}:${P_NUM}")
    FIREWALL_PORTS+=("$P_NUM")
fi

### ==============================================================================
### 3. Directory Setup & Interactive Initialization
### ==============================================================================

if [[ ! -d "$NEXUS_BASE_HOME" ]]; then
    mkdir -p "$NEXUS_BASE_HOME"
fi

### Determine Real Data Path
if [[ -n "$NEXUS_REAL_DATA_DIR" ]] && [[ "$NEXUS_REAL_DATA_DIR" != "$NEXUS_BASE_HOME" ]]; then
    REAL_DATA_PATH="${NEXUS_REAL_DATA_DIR}"
else
    REAL_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
fi

echo ""
echo "Configuring Directories..."
echo "  Target Data Directory: $REAL_DATA_PATH"

### [NEW] Interactive Initialization Check
if [[ -d "$REAL_DATA_PATH" ]] && [[ "$(ls -A "$REAL_DATA_PATH")" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Data directory is NOT empty: $REAL_DATA_PATH"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (delete all data)? [y/N]: " init_confirm
    
    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > Initializing... Removing all contents in $REAL_DATA_PATH"
        rm -rf "${REAL_DATA_PATH:?}"/*
        rm -rf "${NEXUS_BASE_HOME}/nexus-etc-ssl"
    else
        echo "  > Keeping existing data."
    fi
fi

### Create Directories
mkdir -p "${NEXUS_BASE_HOME}/nexus-etc-ssl"
mkdir -p "$REAL_DATA_PATH"
mkdir -p "${REAL_DATA_PATH}/etc"

### Symbolic Link Logic
LINK_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
if [[ "$REAL_DATA_PATH" != "$LINK_DATA_PATH" ]]; then
    if [[ -d "$LINK_DATA_PATH" ]] && [[ ! -L "$LINK_DATA_PATH" ]]; then
        rm -rf "$LINK_DATA_PATH"
    fi
    ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
fi

### Permissions
chown -R 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl"
chown -R 200:200 "${REAL_DATA_PATH}"
[[ -L "$LINK_DATA_PATH" ]] && chown -h 200:200 "$LINK_DATA_PATH"

### ==============================================================================
### 4. Install Certificates (Keytool)
### ==============================================================================

echo ""
echo "Generating SSL keystore..."

JKS_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl/keystore.jks"
PKCS12_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12"

# Only generate if not exists or if we initialized
if [[ ! -f "$JKS_PATH" ]]; then
    openssl pkcs12 -export -in "$NEXUS_CERT" -inkey "$NEXUS_KEY" \
      -out "$PKCS12_PATH" -name nexus -passout pass:password
    
    chown 200:200 "$PKCS12_PATH"

    podman run --rm \
      -v "${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z" \
      --entrypoint keytool \
      "$NEXUS_IMAGE" \
        -importkeystore \
        -srckeystore /opt/sonatype/nexus/etc/ssl/nexus.p12 -srcstoretype PKCS12 \
        -destkeystore /opt/sonatype/nexus/etc/ssl/keystore.jks -deststoretype JKS \
        -srcstorepass password -deststorepass password > /dev/null 2>&1

    chown 200:200 "$JKS_PATH"
    echo "  > Keystore created."
else
    echo "  > Keystore already exists. Skipping generation."
fi

### ==============================================================================
### 5. Construct Nexus Properties
### ==============================================================================

JETTY_XML_LIST="\${jetty.etc}/jetty-requestlog.xml,\${jetty.etc}/jetty.xml"
[[ -n "$NEXUS_PUBLISH_HTTPS" ]] && JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty-https.xml"

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
### 6. Run Nexus Container (Array Method)
### ==============================================================================

echo ""
echo "Constructing Nexus container command..."

if podman ps -a --format "{{.Names}}" | grep -q "^${NEXUS_CONTAINER_NAME}$"; then
    echo "  > Removing existing container..."
    podman rm -f "$NEXUS_CONTAINER_NAME"
fi

# [CHANGED] Constructing command using Bash Array
podman_cmd=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$NEXUS_CONTAINER_NAME"
    "--volume" "${REAL_DATA_PATH}:/nexus-data:Z"
    "--volume" "${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z"
)

# Append Port Arguments (Pre-built array)
podman_cmd+=("${PODMAN_PORT_ARGS[@]}")

# Append Image Name
podman_cmd+=("$NEXUS_IMAGE")

echo "----------------------------------------------------------------"
echo "Command to be executed:"
echo "${podman_cmd[*]}"
echo "----------------------------------------------------------------"

# Execute the array
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
echo "Done."