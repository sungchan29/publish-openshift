#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Basic Info
NEXUS_HOST_NAME="registry.cloudpang.lan"
NEXUS_BASE_HOME="/opt/nexus"

NEXUS_IMAGE="docker.io/sonatype/nexus3:latest"
NEXUS_CONTAINER_NAME="nexus"

### 2. Certificate Configuration
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"
NEXUS_CUSTOM_CERT="" ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt
NEXUS_CUSTOM_KEY=""  ### If empty, defaults to: ${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key

### 3. Data Directory
NEXUS_REAL_DATA_DIR="/data/nexus"

### 4. Port Settings (External Exposure)
### - Leave EMPTY to disable access.
### - Use "Port", "IP:Port", or "IP" (maps to Internal Port automatically).
NEXUS_PUBLISH_HTTPS="172.16.120.28:8443"

### [Dynamic Custom Ports]
### Define list of additional custom port mappings (e.g., Docker Connectors).
### Format: "IP:HostPort:ContainerPort" (Recommended) or "HostPort:ContainerPort"
NEXUS_PUBLISH_CUSTOM_MAP=(
    "172.16.120.28:5000:5000"
    "172.16.120.28:5001:5001"
)

### 5. Internal Container Ports (Defined by Image/Config)
NEXUS_INT_HTTPS="8443"

### 6. Resource Limits
NEXUS_CPU="4"
NEXUS_MEM="4g"

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
### 2. Validation
### ==============================================================================

if [[ $EUID -ne 0 ]]; then echo "[ERROR] This script must be run as root."; exit 1; fi

echo "Checking Prerequisites..."
for cmd in podman keytool openssl; do
    if ! command -v $cmd &> /dev/null; then
        echo "  > [WARNING] Command '$cmd' not found. It might be needed for keystore generation."
    fi
done

if [[ -z "$NEXUS_PUBLISH_HTTP" ]] && [[ -z "$NEXUS_PUBLISH_HTTPS" ]]; then
    echo "[ERROR] Invalid Configuration: At least one of HTTP or HTTPS must be set."
    exit 1
fi

### ==============================================================================
### 3. Certificate Resolution
### ==============================================================================

if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    echo "Resolving certificate paths..."
    if [[ -n "$NEXUS_CUSTOM_CERT" ]]; then SOURCE_CERT="$NEXUS_CUSTOM_CERT"; else SOURCE_CERT="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.crt"; fi
    if [[ -n "$NEXUS_CUSTOM_KEY" ]]; then SOURCE_KEY="$NEXUS_CUSTOM_KEY"; else SOURCE_KEY="${CERT_BASE_DIR}/domain_certs/${NEXUS_HOST_NAME}.key"; fi

    if [[ ! -f "$SOURCE_CERT" ]] || [[ ! -f "$SOURCE_KEY" ]]; then
        echo "[ERROR] Certificate or Key file not found."; exit 1
    fi
    echo "  > Certificate found: $SOURCE_CERT"
fi

### ==============================================================================
### 4. Directory Setup
### ==============================================================================

LOCAL_SSL_PATH="${NEXUS_BASE_HOME}/nexus-etc-ssl"

if [[ -n "$NEXUS_REAL_DATA_DIR" ]] && [[ "$NEXUS_REAL_DATA_DIR" != "$NEXUS_BASE_HOME" ]]; then
    REAL_DATA_PATH="${NEXUS_REAL_DATA_DIR}"
    IS_SPLIT_STORAGE=true
else
    REAL_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
    IS_SPLIT_STORAGE=false
fi

echo "Configuring Directories..."
DATA_EXISTS=false
if [[ -d "$REAL_DATA_PATH" ]] && [[ "$(ls -A "$REAL_DATA_PATH")" ]]; then DATA_EXISTS=true; fi

if [[ "$DATA_EXISTS" == "true" ]]; then
    echo ""
    echo "=================================================================="
    echo " [WARNING] Existing Nexus data found!"
    echo "=================================================================="
    read -p " Do you want to INITIALIZE (DELETE ALL data)? [y/N]: " init_confirm

    if [[ "$init_confirm" =~ ^[Yy]$ ]]; then
        echo "  > Checking running containers..."
        if podman ps --format "{{.Names}}" | grep -q "^${NEXUS_CONTAINER_NAME}$"; then
            echo "[ERROR] Container is running. Please stop it first:"
            echo "        podman stop ${NEXUS_CONTAINER_NAME}"
            exit 1
        fi
        podman rm -f "$NEXUS_CONTAINER_NAME" 2>/dev/null || true

        echo "  > Cleaning Real Data..."
        rm -rf "${REAL_DATA_PATH:?}"/*
        echo "  > Cleaning Base Home..."
        if [[ -d "$NEXUS_BASE_HOME" ]]; then rm -rf "${NEXUS_BASE_HOME:?}"/*; fi
    else
        echo "  > [CANCEL] Installation aborted by user."
        exit 0
    fi
fi

mkdir -p "$LOCAL_SSL_PATH" "${REAL_DATA_PATH}/etc"
if [[ "$IS_SPLIT_STORAGE" == "true" ]]; then
    LINK_DATA_PATH="${NEXUS_BASE_HOME}/nexus-data"
    if [[ -d "$LINK_DATA_PATH" ]]; then rm -rf "$LINK_DATA_PATH"; fi; ln -snf "$REAL_DATA_PATH" "$LINK_DATA_PATH"
else
    LINK_DATA_PATH="$REAL_DATA_PATH"
fi
chown -R 200:200 "${NEXUS_BASE_HOME}" "${REAL_DATA_PATH}"

### ==============================================================================
### 5. Install Certificates & Keystore
### ==============================================================================

JKS_PATH="${LOCAL_SSL_PATH}/keystore.jks"
PKCS12_PATH="${LOCAL_SSL_PATH}/nexus.p12"

if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    if [[ ! -f "$JKS_PATH" ]]; then
        echo "Generating Keystore..."
        openssl pkcs12 -export -in "$SOURCE_CERT" -inkey "$SOURCE_KEY" \
          -out "$PKCS12_PATH" -name nexus -passout pass:password
        chown 200:200 "$PKCS12_PATH"

        ### Convert to JKS using container's keytool
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
        "${keytool_cmd[@]}" > /dev/null 2>&1
        chown 200:200 "$JKS_PATH"
        echo "  > Keystore created at: $JKS_PATH"
    fi
fi

### ==============================================================================
### 6. Construct Configuration (Dynamic Internal Ports)
### ==============================================================================

echo "Generating Nexus Configuration..."

### Start with request log only
JETTY_XML_LIST="\${jetty.etc}/jetty-requestlog.xml"
JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty.xml"

### Add HTTPS config ONLY if enabled
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    JETTY_XML_LIST="${JETTY_XML_LIST},\${jetty.etc}/jetty-https.xml"
fi

PROPERTY_FILE="${REAL_DATA_PATH}/etc/nexus.properties"

### 1. Initialize file with nexus-args
cat <<EOF > "$PROPERTY_FILE"
nexus-args=${JETTY_XML_LIST}
EOF

### 2. Append HTTP port if enabled
if [[ -n "$NEXUS_PUBLISH_HTTP" ]]; then
    cat <<EOF >> "$PROPERTY_FILE"
application-port=${NEXUS_INT_HTTP}
EOF
fi

### 3. Append HTTPS config if enabled (Includes SSL properties)
if [[ -n "$NEXUS_PUBLISH_HTTPS" ]]; then
    cat <<EOF >> "$PROPERTY_FILE"
application-port-ssl=${NEXUS_INT_HTTPS}
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF
fi

chown 200:200 "$PROPERTY_FILE"

### ==============================================================================
### 7. Run Container
### ==============================================================================

echo "Constructing Nexus command..."

### Resolve Main Ports
HTTP_ARG=$(get_podman_port_arg "$NEXUS_PUBLISH_HTTP" "$NEXUS_INT_HTTP" "true")
HTTPS_ARG=$(get_podman_port_arg "$NEXUS_PUBLISH_HTTPS" "$NEXUS_INT_HTTPS" "true")

### [Dynamic Custom Ports] Build Argument Array
### Iterates over the custom map array to create -p flags
CUSTOM_PORT_ARGS=()
for MAPPING in "${NEXUS_PUBLISH_CUSTOM_MAP[@]}"; do
    if [[ -n "$MAPPING" ]]; then
        CUSTOM_PORT_ARGS+=("-p" "$MAPPING")
    fi
done

podman_nexus_cmd=(
    "podman" "run" "-d"
    "--restart" "always"
    "--name" "$NEXUS_CONTAINER_NAME"
    "--cpus" "${NEXUS_CPU}"
    "--memory" "${NEXUS_MEM}"
    "--volume" "${REAL_DATA_PATH}:/nexus-data:Z"
    "--volume" "${LOCAL_SSL_PATH}:/opt/sonatype/nexus/etc/ssl:Z"
    $HTTP_ARG
    $HTTPS_ARG
    "${CUSTOM_PORT_ARGS[@]}"
    "$NEXUS_IMAGE"
)

podman rm -f "$NEXUS_CONTAINER_NAME" 2>/dev/null || true

echo "----------------------------------------------------------------"
echo "Nexus Command:"
echo "${podman_nexus_cmd[*]}"
echo "----------------------------------------------------------------"
"${podman_nexus_cmd[@]}"

echo "  > Nexus started."

### ==============================================================================
### 8. Systemd & Firewall
### ==============================================================================

echo ""
echo "Configuring Systemd & Firewall..."

### Collect Main Ports
FW_PORTS=(
    $(get_port_number "$NEXUS_PUBLISH_HTTP" "")
    $(get_port_number "$NEXUS_PUBLISH_HTTPS" "")
)

### [Dynamic Custom Ports] Extract Host Ports
### Logic: Extract the 2nd field (HostPort) from "IP:HostPort:ContainerPort"
###        Or 1st field if "HostPort:ContainerPort"
for MAPPING in "${NEXUS_PUBLISH_CUSTOM_MAP[@]}"; do
    if [[ -n "$MAPPING" ]]; then
        ### Count number of colons to identify format
        COLON_COUNT=$(tr -cd ':' <<< "$MAPPING" | wc -c)

        if [[ "$COLON_COUNT" -ge 2 ]]; then
            ### Format: IP:HostPort:ContainerPort -> Get Field 2
            PORT=$(echo "$MAPPING" | cut -d: -f2)
        else
        ### Format: HostPort:ContainerPort -> Get Field 1
            PORT=$(echo "$MAPPING" | cut -d: -f1)
        fi

        if [[ -n "$PORT" ]]; then FW_PORTS+=("$PORT"); fi
    fi
done

### Apply Firewall Rules
for PORT in "${FW_PORTS[@]}"; do
    if [[ -n "$PORT" ]]; then
        semanage port -a -t http_port_t -p tcp $PORT 2>/dev/null || true
        firewall-cmd --permanent --zone=public --add-port=${PORT}/tcp >/dev/null 2>&1
    fi
done
firewall-cmd --reload >/dev/null

cd /etc/systemd/system || exit
podman generate systemd --new --files --name "$NEXUS_CONTAINER_NAME" >/dev/null
systemctl daemon-reload
systemctl enable "container-${NEXUS_CONTAINER_NAME}"

### ==============================================================================
### 9. Generate Start Script
### ==============================================================================

START_SCRIPT="${NEXUS_BASE_HOME}/start-nexus.sh"
cat <<EOF > "$START_SCRIPT"
#!/bin/bash
echo "Stopping container..."
podman rm -f ${NEXUS_CONTAINER_NAME} 2>/dev/null || true

echo "Starting Nexus..."
${podman_nexus_cmd[*]}

echo "Nexus started."
EOF
chmod 700 "$START_SCRIPT"

### ==============================================================================
### 10. Display Admin Password Information
### ==============================================================================

ADMIN_PASS_FILE="${LINK_DATA_PATH}/admin.password"

echo ""
echo "----------------------------------------------------------------"
echo " [SUCCESS] Nexus Installation Complete"
echo "----------------------------------------------------------------"
echo " 1. Manual Start Script : $START_SCRIPT"
echo " 2. Systemd Service     : Enabled (container-${NEXUS_CONTAINER_NAME})"
echo ""
echo "=================================================================="
echo " [INFO] Initial Admin Password"
echo "=================================================================="
echo " File Path : $ADMIN_PASS_FILE"
echo ""

if [[ -f "$ADMIN_PASS_FILE" ]]; then
    echo " Password Content:"
    echo "   $(cat "$ADMIN_PASS_FILE")"
else
    echo " [NOTE] Nexus is currently initializing (takes 2-5 minutes)."
    echo "        The password file has not been generated yet."
    echo ""
    echo " To check later, run:"
    echo "   cat $ADMIN_PASS_FILE"
fi
echo "=================================================================="
echo ""