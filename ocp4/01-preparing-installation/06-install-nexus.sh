#!/bin/bash

REGISTRY_DOMAIN="registry.cloudpang.lan"
NEXUS_BASE_HOME="/opt/sonatype"
CERT_BASE_DIR="/root/ocp4/support-system/custom-certs"

### (Optional) Real data directory path
###   This path will be mounted directly into the container.
###   If left empty (""), ${NEXUS_BASE_HOME}/nexus-data will be used.
###   Example: "/mnt/nexus-data"
NEXUS_REAL_DATA_DIR=""

### (Optional) Nexus port settings (uses default if left empty)
NEXUS_PORT_HTTP=""
NEXUS_PORT_HTTPS=""
NEXUS_PORT_DOCKER_01=""
NEXUS_PORT_DOCKER_02=""


### ==============================================================================
### 1. Base Variables and Certificate Setup
### ==============================================================================

### (Optional) Nexus port settings (uses default if left empty)
NEXUS_PORT_HTTP="${NEXUS_PORT_HTTP:-8080}"                  # Nexus UI (HTTP)
NEXUS_PORT_HTTPS="${NEXUS_PORT_HTTPS:-8443}"                # Nexus UI (HTTPS)
NEXUS_PORT_DOCKER_01="${NEXUS_PORT_DOCKER_01:-5000}"        # Docker Registry
NEXUS_PORT_DOCKER_02="${NEXUS_PORT_DOCKER_02:-5001}"        # Docker Registry

NEXUS_CERT="${CERT_BASE_DIR}/domain_certs/$REGISTRY_DOMAIN.crt"
NEXUS_KEY="${CERT_BASE_DIR}/domain_certs/$REGISTRY_DOMAIN.key"

### ==============================================================================
### 2. Preparation (Cleanup Existing Directories)
### ==============================================================================

if [[ -d "$NEXUS_BASE_HOME" ]]; then
    echo "Cleaning up existing configuration in $NEXUS_BASE_HOME..."
    ### This also removes the convenience symlink if it exists
    rm -Rf "$NEXUS_BASE_HOME"/*
fi

### Check for certificate files
if [[ -f "$NEXUS_CERT" ]]; then
    echo "Using certificate: $NEXUS_CERT"
else
    echo "Certificate file not found: $NEXUS_CERT"
    exit 1
fi
if [[ -f "$NEXUS_KEY" ]]; then
    echo "Using key: $NEXUS_KEY"
else
    echo "Key file not found: $NEXUS_KEY"
    exit 1
fi

### ==============================================================================
### 3. Create Directories and Set Ownership (UID 200)
### ==============================================================================

### Data Directory Setup
if [[ -n "$NEXUS_REAL_DATA_DIR" ]]; then
    ### 1. Use the custom path for all operations
    DATA_DIR_TARGET="${NEXUS_REAL_DATA_DIR}"
    echo "Using custom data directory: $DATA_DIR_TARGET"

    ### 2. Create the real directory and set permissions
    mkdir -p "${DATA_DIR_TARGET}/etc"
    chown -R 200:200 "${DATA_DIR_TARGET}"

    ### 3. Create symlink for admin convenience
    ###    This symlink will NOT be used by Podman, only by the human admin.
    echo "Creating symlink for admin convenience at ${NEXUS_BASE_HOME}/nexus-data"
    ln -s "${DATA_DIR_TARGET}" "${NEXUS_BASE_HOME}/nexus-data"
    chown -h 200:200 "${NEXUS_BASE_HOME}/nexus-data"

else
    ### Use the default path inside NEXUS_BASE_HOME
    DATA_DIR_TARGET="${NEXUS_BASE_HOME}/nexus-data"
    echo "Using standard data directory: $DATA_DIR_TARGET"

    ### Create the directory and set permissions
    mkdir -p "${DATA_DIR_TARGET}/etc"
    chown -R 200:200 "${DATA_DIR_TARGET}"
fi

### Create SSL configuration directory (always in NEXUS_BASE_HOME)
mkdir -p ${NEXUS_BASE_HOME}/nexus-etc-ssl
chown -R 200:200 ${NEXUS_BASE_HOME}/nexus-etc-ssl

### ==============================================================================
### 4. Create Keystore (PKCS12 -> JKS)
### ==============================================================================

### Convert certificate and private key to PKCS12
openssl pkcs12 -export -in "$NEXUS_CERT" -inkey "$NEXUS_KEY" \
  -out "${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12" \
  -name nexus -passout pass:password

chown 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12"

### Use keytool from the Nexus container image to convert PKCS12 to JKS
podman run --rm -v ${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z \
  --entrypoint keytool docker.io/sonatype/nexus3:latest \
    -importkeystore -srckeystore /opt/sonatype/nexus/etc/ssl/nexus.p12 -srcstoretype PKCS12 \
    -destkeystore /opt/sonatype/nexus/etc/ssl/keystore.jks -deststoretype JKS \
    -srcstorepass password -deststorepass password

chown 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl/keystore.jks"

### ==============================================================================
### 5. Create Nexus Configuration (nexus.properties)
### ==============================================================================

### Create nexus.properties in the REAL data directory ($DATA_DIR_TARGET)
cat <<EOF > ${DATA_DIR_TARGET}/etc/nexus.properties
### Nexus runtime arguments (Enable HTTP, HTTPS, request log)
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-https.xml,\${jetty.etc}/jetty-requestlog.xml

### Port settings (using variables)
application-port=${NEXUS_PORT_HTTP}
application-port-ssl=${NEXUS_PORT_HTTPS}

### SSL Keystore settings
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF

### Set ownership of nexus.properties in the REAL data directory
chown 200:200 ${DATA_DIR_TARGET}/etc/nexus.properties

### ==============================================================================
### 6. Run Nexus Container
### ==============================================================================

echo "Starting Nexus container..."
podman run -d \
  -p ${NEXUS_PORT_HTTP}:${NEXUS_PORT_HTTP} \
  -p ${NEXUS_PORT_HTTPS}:${NEXUS_PORT_HTTPS} \
  -p ${NEXUS_PORT_DOCKER_01}:${NEXUS_PORT_DOCKER_01} \
  -p ${NEXUS_PORT_DOCKER_02}:${NEXUS_PORT_DOCKER_02} \
  --name nexus \
  -v ${DATA_DIR_TARGET}:/nexus-data:Z \
  -v ${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z \
  docker.io/sonatype/nexus3:latest

sleep 10

echo "Nexus is starting. Initial admin password will be shown below:"
echo "============================================================"
### Cat the admin.password file from the REAL data directory path
cat ${DATA_DIR_TARGET}/admin.password
echo "============================================================"
echo "It is also located in ${DATA_DIR_TARGET}/admin.password on the server."


### ==============================================================================
### 7. Configure Firewall and SELinux Ports
### ==============================================================================
echo "Configuring SELinux and Firewall..."

### Set SELinux port context (ignore errors if port already set)
semanage port -a -t http_port_t -p tcp ${NEXUS_PORT_HTTP} || true
semanage port -a -t http_port_t -p tcp ${NEXUS_PORT_HTTPS} || true
semanage port -a -t http_port_t -p tcp ${NEXUS_PORT_DOCKER_01} || true
semanage port -a -t http_port_t -p tcp ${NEXUS_PORT_DOCKER_02} || true

### Open firewall ports
firewall-cmd --permanent --zone=public \
  --add-port=${NEXUS_PORT_HTTP}/tcp \
  --add-port=${NEXUS_PORT_HTTPS}/tcp \
  --add-port=${NEXUS_PORT_DOCKER_01}/tcp \
  --add-port=${NEXUS_PORT_DOCKER_02}/tcp

firewall-cmd --reload