#!/bin/bash

### Define the base directory for Nexus
NEXUS_BASE_HOME="/opt/sonatype"

### Define file paths for certificates and keys
NEXUS_CERT="/root/ocp4/certs/domain_certs/nexus.cloudpang.tistory.disconnected.crt"
NEXUS_KEY="/root/ocp4/certs/domain_certs/nexus.cloudpang.tistory.disconnected.key"

if [[ -d "$NEXUS_BASE_HOME" ]]; then
    rm -Rf "$NEXUS_BASE_HOME"/*
fi

### Create directories and set ownership to UID 200 (Nexus default user)
mkdir -p ${NEXUS_BASE_HOME}/nexus-data/etc && chown -R 200 ${NEXUS_BASE_HOME}/nexus-data
mkdir -p ${NEXUS_BASE_HOME}/nexus-etc-ssl  && chown -R 200 ${NEXUS_BASE_HOME}/nexus-etc-ssl

### Convert certificate and private key to PKCS12 format for Java Keystore compatibility
openssl pkcs12 -export -in "$NEXUS_CERT" -inkey "$NEXUS_KEY" \
  -out "${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12" \
  -name nexus -passout pass:password

### Set ownership of nexus.p12 to UID 200 for Nexus container
chown 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl/nexus.p12"

### Use keytool from the Nexus container image to convert PKCS12 to JKS
podman run --rm -v ${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z \
  --entrypoint keytool docker.io/sonatype/nexus3:latest \
    -importkeystore -srckeystore /opt/sonatype/nexus/etc/ssl/nexus.p12 -srcstoretype PKCS12 \
    -destkeystore /opt/sonatype/nexus/etc/ssl/keystore.jks -deststoretype JKS \
    -srcstorepass password -deststorepass password

### Set ownership of keystore.jks to UID 200 for Nexus container
chown 200:200 "${NEXUS_BASE_HOME}/nexus-etc-ssl/keystore.jks"

### Create nexus.properties to configure Nexus for HTTPS
cat <<EOF > ${NEXUS_BASE_HOME}/nexus-data/etc/nexus.properties
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-https.xml,\${jetty.etc}/jetty-requestlog.xml
application-port-ssl=8443
ssl.etc=/opt/sonatype/nexus/etc/ssl
ssl.keystore=keystore.jks
ssl.keystorepassword=password
ssl.keypassword=password
EOF

### Set ownership of nexus.properties to UID 200 for Nexus container
chown 200:200 ${NEXUS_BASE_HOME}/nexus-data/etc/nexus.properties

### Run the Nexus container with HTTP, HTTPS, and Docker registry ports exposed
podman run -d -p 8081:8081 -p 8443:8443 -p 5000:5000 --name nexus \
  -v ${NEXUS_BASE_HOME}/nexus-data:/nexus-data:Z \
  -v ${NEXUS_BASE_HOME}/nexus-etc-ssl:/opt/sonatype/nexus/etc/ssl:Z \
  docker.io/sonatype/nexus3:latest

sleep 10

echo "Your admin user password is located in $NEXUS_BASE_HOME/nexus-data/admin.password on the server."
cat $NEXUS_BASE_HOME/nexus-data/admin.password
