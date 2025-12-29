#!/bin/bash

### ==============================================================================
### 1. Unified User Configuration
### ==============================================================================

### --- Server IP Configuration ---
### DNS Master Server IP address (Required)
### This IP is used in SOA/NS records and for role detection.
DNS_MASTER_IP="172.16.120.29"

### DNS Slave Server IP address (Optional)
### Set this if you have a secondary DNS server.
### Leave empty ("") if you are configuring a Master-only setup.
DNS_SLAVE_IP=""

### --- BIND Options ---
### ACL for 'listen-on' directive in named.conf
### Determines which interfaces/IPs the DNS server listens on.
### Example: "any;" or "127.0.0.1; 192.168.1.10;" (Semicolon is mandatory)
BIND_ACL_LISTEN="localhost; 10.10.0.0/24; 172.16.120.0/24;"

### ACL for 'allow-query' directive in named.conf
### Determines which clients are allowed to query this DNS server.
### Example: "localhost; 10.0.0.0/8;" (Semicolon is mandatory)
BIND_ACL_QUERY="localhost; 10.10.0.0/24; 172.16.120.0/24;"

### Enable or Disable Recursion
### Set to "yes" to allow recursive queries (acting as a resolver).
### Set to "no" for an authoritative-only server.
BIND_RECURSION="no"

### Forwarders Configuration
### Upstream DNS servers to forward queries to if not found locally.
### Example: "8.8.8.8; 8.8.4.4;"
### Leave empty ("") to disable forwarding and use root hints.
BIND_FORWARDERS=""

### Platform "none" DNS requirements
### In OpenShift Container Platform deployments, DNS name resolution is required for the following components:
###   - The Kubernetes API
###   - The OpenShift Container Platform application wildcard
###   - The control plane and compute machines
### Reverse DNS resolution is also required for the Kubernetes API, the control plane machines, and the compute machines.

### --- Zone Data Definitions ---
### List of Zone Identifiers to process
TARGET_ZONES=("ZONE01" "ZONE02" "ZONE03")

### [GROUP 01]
### Zone Name (Domain Name)
FQDN_ZONE01_NAME="cloudpang.lan"

### List of FQDNs for A Records (Format: "hostname:IP")
FQDN_ZONE01_LIST=(
    "registry:172.16.120.28"
      "gitlab:172.16.120.29"
        "quay:172.16.120.28"
       "host1:172.16.120.28"
       "host2:172.16.120.29"
    )

### List of FQDNs for A + PTR Records
FQDN_PTR_ZONE01_LIST=("")

### List of PTR Records (Reverse only)
PTR_ZONE01_LIST=("")

### [GROUP 02]
FQDN_ZONE02_NAME="ocp4-hub.cloudpang.lan"
FQDN_ZONE02_LIST=(
    "*.apps:172.16.120.100"
    )
FQDN_PTR_ZONE02_LIST=(
        "api:172.16.120.100"
    "api-int:172.16.120.100"
        "sno:172.16.120.100"
    )
PTR_ZONE02_LIST=("")

### [GROUP 03]
FQDN_ZONE03_NAME="ocp4-mgc01.cloudpang.lan"
FQDN_ZONE03_LIST=(
    "*.apps:172.16.120.29"
    )
FQDN_PTR_ZONE03_LIST=(
        "api:172.16.120.29"
    "api-int:172.16.120.29"
     "mst01:172.16.120.111"
     "mst02:172.16.120.112"
     "mst03:172.16.120.113"
     "ifr01:172.16.120.121"
     "ifr02:172.16.120.122"
     "wkr01:172.16.120.131"
     "wkr02:172.16.120.132"
    )
PTR_ZONE03_LIST=("")

### --- Output Directory Path ---
OUTPUT_DIR="./named_zones"
CONF_DIR="/etc"
NAMED_CONF="${CONF_DIR}/named.conf"
RFC1912_ZONES="${CONF_DIR}/named.rfc1912.zones"


######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### Logging Helpers
log_info() {
    printf "%-8s%-80s\n" "[INFO]" "$1"
}

log_warn() {
    printf "%-8s%-80s\n" "[WARN]" "$1"
}

log_error() {
    printf "%-8s%-80s\n" "[ERROR]" "$1"
}

### Command Execution Wrapper
### This functions executes the command and logs it
execute() {
    local cmd="$*"
    log_info "    > $cmd"
    "$@"
    local status=$?
    if [[ $status -ne 0 ]]; then
        log_error "Command failed with status $status: $cmd"
        exit $status
    fi
}

### Zone Header Generator
create_header() {
    local zone=$1
    local current_date=$(date +%Y%m%d)01
    local FMT="%-15s %-7s %-7s %s\n"
    local SOA_INDENT="                                "

    echo "\$TTL 86400"
    printf "$FMT" "@" "IN" "SOA" "ns1.${zone}. root.${zone}. ("
    printf "%s%-11s ; Serial\n"  "$SOA_INDENT" "$current_date"
    printf "%s%-11s ; Refresh\n" "$SOA_INDENT" "3600"
    printf "%s%-11s ; Retry\n"   "$SOA_INDENT" "1800"
    printf "%s%-11s ; Expire\n"  "$SOA_INDENT" "604800"
    printf "%s%-11s ; Minimum TTL\n" "$SOA_INDENT" "86400 )"
    echo ";"
    printf "$FMT" "" "IN" "NS" "ns1.${zone}."
    [[ -n "$DNS_SLAVE_IP" ]] && printf "$FMT" "" "IN" "NS" "ns2.${zone}."
    printf "$FMT" "ns1" "IN" "A" "${DNS_MASTER_IP}"
    [[ -n "$DNS_SLAVE_IP" ]] && printf "$FMT" "ns2" "IN" "A" "${DNS_SLAVE_IP}"
}

### 1. Prerequisites Check
log_info "=== Prerequisites Check"

if [[ $EUID -ne 0 ]]; then
    log_error "Run as root."
    exit 1
fi

if ! rpm -q bind > /dev/null 2>&1; then
    log_error "BIND (named) package is NOT installed."
    log_info  "Please install BIND manually using: dnf install -y bind bind-utils"
    exit 1
else
    log_info "--- BIND installed. Proceeding..."
fi

if [[ ! -f "$NAMED_CONF" ]] || [[ ! -f "$RFC1912_ZONES" ]]; then
    log_error "Critical BIND configuration files not found in /etc/."
    exit 1
fi

### 2. Configuration Backup
log_info "=== Configuration Backup"

if [[ ! -f "${NAMED_CONF}.orig" ]]; then
    log_info "--- Creating backup: named.conf.orig"
    execute cp -p "$NAMED_CONF" "${NAMED_CONF}.orig"
fi

if [[ ! -f "${RFC1912_ZONES}.orig" ]]; then
    log_info "--- Creating backup: named.rfc1912.zones.orig"
    execute cp -p "$RFC1912_ZONES" "${RFC1912_ZONES}.orig"
fi

### 3. Artifact Generation
log_info "=== Artifact Generation"
log_info "--- Cleaning and preparing output directory: $OUTPUT_DIR"

execute rm -rf "$OUTPUT_DIR"
execute mkdir -p "$OUTPUT_DIR"

ENABLE_SLAVE="false"
if [[ -n "$DNS_SLAVE_IP" ]]; then ENABLE_SLAVE="true"; fi

### Copy configs for modification
log_info "--- Copying original configs to output directory..."
execute cp "${NAMED_CONF}.orig" "$OUTPUT_DIR/named.conf"
execute cp "${RFC1912_ZONES}.orig" "$OUTPUT_DIR/named.rfc1912.zones"

MASTER_CFG="$OUTPUT_DIR/named.master.conf"
SLAVE_CFG="$OUTPUT_DIR/named.slave.conf"
PROCESSED_REV_ZONES=""

echo "### Master Config" > "$MASTER_CFG"
echo "### Slave Config" > "$SLAVE_CFG"

### Loop through Zones
for ID in "${TARGET_ZONES[@]}"; do
    VAR_DOMAIN="FQDN_${ID}_NAME"; DOMAIN="${!VAR_DOMAIN}"
    VAR_LIST_F="FQDN_${ID}_LIST[@]"; LIST_F=("${!VAR_LIST_F}")
    VAR_LIST_FP="FQDN_PTR_${ID}_LIST[@]"; LIST_FP=("${!VAR_LIST_FP}")
    VAR_LIST_P="PTR_${ID}_LIST[@]"; LIST_P=("${!VAR_LIST_P}")

    [[ -z "$DOMAIN" ]] && continue

    log_info "--- Processing Zone: $DOMAIN"

    ### Extract Sample IP
    SAMPLE_ENTRY=""
    ALL=("${LIST_F[@]}" "${LIST_FP[@]}" "${LIST_P[@]}")
    for item in "${ALL[@]}"; do [[ "$item" == *:* ]] && { SAMPLE_ENTRY="$item"; break; }; done
    [[ -z "$SAMPLE_ENTRY" ]] && continue

    SAMPLE_IP=${SAMPLE_ENTRY#*:}
    REV_ZONE=$(echo $SAMPLE_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    FWD_FILE="$OUTPUT_DIR/${DOMAIN}.zone"
    REV_FILE="$OUTPUT_DIR/${REV_ZONE}.zone"
    REC_FMT="%-15s %-7s %-7s %s\n"

    create_header "$DOMAIN" > "$FWD_FILE"
    [[ ! -f "$REV_FILE" ]] && create_header "$DOMAIN" > "$REV_FILE"

    ### Write Records (Robust whitespace handling)
    if [[ "${LIST_F[*]}" == *:* ]]; then
        echo ";" >> "$FWD_FILE"
        for e in "${LIST_F[@]}"; do
            if [[ "$e" == *:* ]]; then
                 NAME=$(echo "${e%:*}" | xargs)
                 IP=$(echo "${e#*:}" | xargs)
                 printf "$REC_FMT" "$NAME" "IN" "A" "$IP" >> "$FWD_FILE"
            fi
        done
    fi

    if [[ "${LIST_FP[*]}" == *:* ]]; then
        echo ";" >> "$FWD_FILE"
        echo ";" >> "$REV_FILE"
        for e in "${LIST_FP[@]}"; do
            if [[ "$e" == *:* ]]; then
                NAME=$(echo "${e%:*}" | xargs)
                IP=$(echo "${e#*:}" | xargs)
                LAST_OCTET=$(echo $IP | awk -F. '{print $4}')
                printf "$REC_FMT" "$NAME" "IN" "A" "$IP" >> "$FWD_FILE"
                printf "$REC_FMT" "$LAST_OCTET" "IN" "PTR" "${NAME}.${DOMAIN}." >> "$REV_FILE"
            fi
        done
    fi

    if [[ "${LIST_P[*]}" == *:* ]]; then
        echo ";" >> "$REV_FILE"
        for e in "${LIST_P[@]}"; do
            if [[ "$e" == *:* ]]; then
                NAME=$(echo "${e%:*}" | xargs)
                IP=$(echo "${e#*:}" | xargs)
                LAST_OCTET=$(echo $IP | awk -F. '{print $4}')
                printf "$REC_FMT" "$LAST_OCTET" "IN" "PTR" "${NAME}.${DOMAIN}." >> "$REV_FILE"
            fi
        done
    fi

    ### Config Snippets
    echo "zone \"$DOMAIN\" IN { type master; file \"${DOMAIN}.zone\"; allow-update { none; };" >> "$MASTER_CFG"
    [[ "$ENABLE_SLAVE" == "true" ]] && echo "    allow-transfer { $DNS_SLAVE_IP; };" >> "$MASTER_CFG"
    echo "};" >> "$MASTER_CFG"

    if [[ "$ENABLE_SLAVE" == "true" ]]; then
        echo "zone \"$DOMAIN\" IN { type slave; masters { $DNS_MASTER_IP; }; file \"slaves/${DOMAIN}.zone\"; };" >> "$SLAVE_CFG"
    fi

    if [[ "$PROCESSED_REV_ZONES" != *"$REV_ZONE"* ]]; then
        echo "zone \"$REV_ZONE\" IN { type master; file \"${REV_ZONE}.zone\"; allow-update { none; };" >> "$MASTER_CFG"
        [[ "$ENABLE_SLAVE" == "true" ]] && echo "    allow-transfer { $DNS_SLAVE_IP; };" >> "$MASTER_CFG"
        echo "};" >> "$MASTER_CFG"

        if [[ "$ENABLE_SLAVE" == "true" ]]; then
            echo "zone \"$REV_ZONE\" IN { type slave; masters { $DNS_MASTER_IP; }; file \"slaves/${REV_ZONE}.zone\"; };" >> "$SLAVE_CFG"
        fi
        PROCESSED_REV_ZONES="$PROCESSED_REV_ZONES $REV_ZONE"
    fi
done

### 4. Configuration Modification
log_info "=== Configuration Modification"
TARGET_NAMED_CONF="$OUTPUT_DIR/named.conf"

log_info "--- Updating 'listen-on'..."
execute sed -i -E "s|listen-on port 53\s*\{[^}]*\};|listen-on port 53 { ${BIND_ACL_LISTEN} };|g" "$TARGET_NAMED_CONF"

log_info "--- Updating 'allow-query'..."
execute sed -i -E "s|allow-query\s*\{[^}]*\};|allow-query     { ${BIND_ACL_QUERY} };|g" "$TARGET_NAMED_CONF"

log_info "--- Updating 'recursion' and 'forwarders'..."
execute sed -i -E "s|^\s*forwarders|// forwarders|g" "$TARGET_NAMED_CONF"

if [[ -n "$BIND_FORWARDERS" ]]; then
    REPL="recursion ${BIND_RECURSION};\n\tforwarders { ${BIND_FORWARDERS} };"
else
    REPL="recursion ${BIND_RECURSION};"
fi
execute sed -i -E "s|recursion\s+[^;]+;|${REPL}|g" "$TARGET_NAMED_CONF"

log_info "--- Finalizing named.rfc1912.zones..."
echo "" >> "$OUTPUT_DIR/named.rfc1912.zones"
echo "### Custom Zone Definitions" >> "$OUTPUT_DIR/named.rfc1912.zones"
echo "include \"/etc/named/named.custom.conf\";" >> "$OUTPUT_DIR/named.rfc1912.zones"


### 5. Installer Generation
log_info "=== Installer Generation"
log_info "--- Creating 'install.sh'..."

INSTALL_SCRIPT="$OUTPUT_DIR/install.sh"

cat > "$INSTALL_SCRIPT" <<EOF
#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. Network Settings
DNS_MASTER_IP="${DNS_MASTER_IP}"
DNS_SLAVE_IP="${DNS_SLAVE_IP}"

### 2. File Paths
SOURCE_DIR="\$(dirname "\$(realpath "\$0")")"
CONF_DIR="/etc"
NAMED_BASE_DIR="/etc/named"
ZONE_DIR="/var/named"
SLAVE_ZONE_DIR="/var/named/slaves"

### 3. Service Info
SERVICE_NAME="named"


######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### Logging Helpers
log_info() {
    printf "%-8s%-80s\\\n" "[INFO]" "\$1"
}

log_warn() {
    printf "%-8s%-80s\\\n" "[WARN]" "\$1"
}

log_error() {
    printf "%-8s%-80s\\\n" "[ERROR]" "\$1"
}

### Command Execution Wrapper
execute() {
    local cmd="\$*"
    log_info "    > \$cmd"
    "\$@"
    local status=\$?
    if [[ \$status -ne 0 ]]; then
        log_error "Critical Error. Exit Code \$status. Aborting."
        exit \$status
    fi
}

### 1. Prerequisites
if [[ \$EUID -ne 0 ]]; then log_error "Run as root."; exit 1; fi

### 2. Role Detection
log_info "=== Role Detection"
if [[ "\$1" == "MASTER" ]] || [[ "\$1" == "SLAVE" ]]; then
    MY_ROLE="\$1"
    log_info "  > Manual Override: \$MY_ROLE"
else
    MY_ROLE="UNKNOWN"
    CURRENT_IPS=\$(hostname -I)
    for IP in \$CURRENT_IPS; do
        if [[ "\$IP" == "\$DNS_MASTER_IP" ]]; then
            MY_ROLE="MASTER"
            break
        elif [[ -n "\$DNS_SLAVE_IP" ]] && [[ "\$IP" == "\$DNS_SLAVE_IP" ]]; then
            MY_ROLE="SLAVE"
            break
        fi
    done
fi

if [[ "\$MY_ROLE" == "UNKNOWN" ]]; then
    log_error "Could not determine server role. Run with ./install.sh MASTER or SLAVE"
    exit 1
fi
log_info "--- Detected Role: \$MY_ROLE"

### 3. Configuration Setup
log_info "=== Configuration Setup"
log_info "--- Copying core configuration files..."

### Copy modified named.conf
execute cp -f "\$SOURCE_DIR/named.conf" "\$CONF_DIR/named.conf"
execute chown root:named "\$CONF_DIR/named.conf"
execute chmod 640 "\$CONF_DIR/named.conf"

### Copy modified named.rfc1912.zones
execute cp -f "\$SOURCE_DIR/named.rfc1912.zones" "\$CONF_DIR/named.rfc1912.zones"
execute chown root:named "\$CONF_DIR/named.rfc1912.zones"
execute chmod 640 "\$CONF_DIR/named.rfc1912.zones"

### Copy Custom Zones Config
log_info "--- Deploying custom zone definitions..."
if [[ "\$MY_ROLE" == "MASTER" ]]; then
    execute cp -f "\$SOURCE_DIR/named.master.conf" "\$NAMED_BASE_DIR/named.custom.conf"
else
    execute cp -f "\$SOURCE_DIR/named.slave.conf" "\$NAMED_BASE_DIR/named.custom.conf"
fi
execute chown root:named "\$NAMED_BASE_DIR/named.custom.conf"
execute chmod 640 "\$NAMED_BASE_DIR/named.custom.conf"


### 4. Zone File Deployment
log_info "=== Zone File Deployment"

if [[ "\$MY_ROLE" == "MASTER" ]]; then
    log_info "--- Master Node: Deploying zone files..."
    execute cp -f "\$SOURCE_DIR"/*.zone "\$ZONE_DIR/"
    execute chown root:named "\$ZONE_DIR"/*.zone
    execute chmod 640 "\$ZONE_DIR"/*.zone
elif [[ "\$MY_ROLE" == "SLAVE" ]]; then
    log_info "--- Slave Node: Checking slave directory..."
    if [[ ! -d "\$SLAVE_ZONE_DIR" ]]; then
        execute mkdir -p "\$SLAVE_ZONE_DIR"
    fi
    execute chown named:named "\$SLAVE_ZONE_DIR"
    execute chmod 770 "\$SLAVE_ZONE_DIR"
fi

### 5. Zone File Verification (Master Only)
### Iterate through deployed zone files and run named-checkzone
if [[ "\$MY_ROLE" == "MASTER" ]]; then
    log_info "=== Zone Verification"

    ### Check if any zone files exist
    if ls "\$ZONE_DIR"/*.zone 1> /dev/null 2>&1; then
        for f in "\$ZONE_DIR"/*.zone; do
            zone_name=\$(basename "\$f" .zone)

            log_info "--- Checking syntax for zone: \$zone_name"
            execute named-checkzone "\$zone_name" "\$f"
        done
    else
        log_warn "No zone files found in \$ZONE_DIR to verify."
    fi
fi

### 6. Service Management
log_info "=== Service Management"
log_info "--- Verifying configuration syntax..."

execute named-checkconf "\$CONF_DIR/named.conf"

log_info "--- Restarting DNS service..."
execute systemctl enable \$SERVICE_NAME --now
execute systemctl restart \$SERVICE_NAME

### 7. Completion
log_info "----------------------------------------------------------------"
log_info " [SUCCESS] DNS Installation Complete"
log_info "----------------------------------------------------------------"
log_info "  Role: \$MY_ROLE"
log_info "  Service: \$SERVICE_NAME (Restarted)"
systemctl status \$SERVICE_NAME --no-pager -l
echo ""
EOF

### Make the generated installer executable
chmod +x "$INSTALL_SCRIPT"

log_info "----------------------------------------------------------------"
log_info " [SUCCESS] Generation Complete"
log_info "----------------------------------------------------------------"
log_info "  Output Dir: $OUTPUT_DIR"
log_info "  Next Step : cd $OUTPUT_DIR && ./install.sh"
echo ""