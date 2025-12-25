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
BIND_RECURSION="yes"

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

### ==============================================================================
### 2. Logic to Generate Zone Files & Configs
### ==============================================================================
echo ">>> [1/2] Starting DNS artifact generation..."

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

ENABLE_SLAVE="false"
if [ -n "$DNS_SLAVE_IP" ]; then ENABLE_SLAVE="true"; fi

MASTER_CFG="$OUTPUT_DIR/named.master.conf"
SLAVE_CFG="$OUTPUT_DIR/named.slave.conf"
PROCESSED_REV_ZONES=""

echo "### Master Config" > "$MASTER_CFG"
echo "### Slave Config" > "$SLAVE_CFG"

### Function: Create Zone Header
create_header() {
    local zone=$1
    local current_date=$(date +%Y%m%d)01

    local FMT="%-15s %-7s %-7s %s\n"
    local SOA_INDENT="                                " ### 32 spaces for SOA params

    echo "\$TTL 86400"

    ### SOA Record
    printf "$FMT" "@" "IN" "SOA" "ns1.${zone}. root.${zone}. ("
    printf "%s%-11s ; Serial\n"  "$SOA_INDENT" "$current_date"
    printf "%s%-11s ; Refresh\n" "$SOA_INDENT" "3600"
    printf "%s%-11s ; Retry\n"   "$SOA_INDENT" "1800"
    printf "%s%-11s ; Expire\n"  "$SOA_INDENT" "604800"
    printf "%s%-11s ; Minimum TTL\n" "$SOA_INDENT" "86400 )"
    echo ";"

    ### NS Records
    printf "$FMT" "" "IN" "NS" "ns1.${zone}."
    if [ "$ENABLE_SLAVE" == "true" ]; then
        printf "$FMT" "" "IN" "NS" "ns2.${zone}."
    fi

    ### NS A Records
    printf "$FMT" "ns1" "IN" "A" "${DNS_MASTER_IP}"
    if [ "$ENABLE_SLAVE" == "true" ]; then
        printf "$FMT" "ns2" "IN" "A" "${DNS_SLAVE_IP}"
    fi
}

### Loop through Zones
for ID in "${TARGET_ZONES[@]}"; do
    VAR_DOMAIN="FQDN_${ID}_NAME"; DOMAIN="${!VAR_DOMAIN}"
    VAR_LIST_F="FQDN_${ID}_LIST[@]"; LIST_F=("${!VAR_LIST_F}")
    VAR_LIST_FP="FQDN_PTR_${ID}_LIST[@]"; LIST_FP=("${!VAR_LIST_FP}")
    VAR_LIST_P="PTR_${ID}_LIST[@]"; LIST_P=("${!VAR_LIST_P}")

    [ -z "$DOMAIN" ] && continue

    ### Extract Sample IP
    SAMPLE_ENTRY=""
    ALL=("${LIST_F[@]}" "${LIST_FP[@]}" "${LIST_P[@]}")
    for item in "${ALL[@]}"; do [[ "$item" == *:* ]] && { SAMPLE_ENTRY="$item"; break; }; done
    [ -z "$SAMPLE_ENTRY" ] && continue

    SAMPLE_IP=${SAMPLE_ENTRY#*:}
    REV_ZONE=$(echo $SAMPLE_IP | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    FWD_FILE="$OUTPUT_DIR/${DOMAIN}.zone"
    REV_FILE="$OUTPUT_DIR/${REV_ZONE}.zone"

    ### Record Format
    REC_FMT="%-15s %-7s %-7s %s\n"

    ### Write Headers
    create_header "$DOMAIN" > "$FWD_FILE"
    [ ! -f "$REV_FILE" ] && create_header "$DOMAIN" > "$REV_FILE"

    ### Write Records with Separators

    ### 1. FQDN List (A Records Only)
    ### Check if list has valid data (contains ':')
    if [[ "${LIST_F[*]}" == *:* ]]; then
        echo ";" >> "$FWD_FILE"
        for e in "${LIST_F[@]}"; do
            if [[ "$e" == *:* ]]; then
                 NAME=${e%:*}
                 IP=${e#*:}
                 printf "$REC_FMT" "$NAME" "IN" "A" "$IP" >> "$FWD_FILE"
            fi
        done
    fi

    ### 2. FQDN + PTR List
    if [[ "${LIST_FP[*]}" == *:* ]]; then
        echo ";" >> "$FWD_FILE"
        echo ";" >> "$REV_FILE"

        for e in "${LIST_FP[@]}"; do
            if [[ "$e" == *:* ]]; then
                NAME=${e%:*}
                IP=${e#*:}
                LAST_OCTET=$(echo $IP | awk -F. '{print $4}')

                ### Forward
                printf "$REC_FMT" "$NAME" "IN" "A" "$IP" >> "$FWD_FILE"
                ### Reverse
                printf "$REC_FMT" "$LAST_OCTET" "IN" "PTR" "${NAME}.${DOMAIN}." >> "$REV_FILE"
            fi
        done
    fi

    ### 3. PTR Only List
    if [[ "${LIST_P[*]}" == *:* ]]; then
        echo ";" >> "$REV_FILE"

        for e in "${LIST_P[@]}"; do
            if [[ "$e" == *:* ]]; then
                NAME=${e%:*}
                IP=${e#*:}
                LAST_OCTET=$(echo $IP | awk -F. '{print $4}')

                ### Reverse
                printf "$REC_FMT" "$LAST_OCTET" "IN" "PTR" "${NAME}.${DOMAIN}." >> "$REV_FILE"
            fi
        done
    fi

    ### Write Config Snippets
    ### Master Forward
    echo "zone \"$DOMAIN\" IN {" >> "$MASTER_CFG"
    echo "    type master;" >> "$MASTER_CFG"
    echo "    file \"${DOMAIN}.zone\";" >> "$MASTER_CFG"
    echo "    allow-update { none; };" >> "$MASTER_CFG"
    [ "$ENABLE_SLAVE" == "true" ] && echo "    allow-transfer { $DNS_SLAVE_IP; };" >> "$MASTER_CFG"
    echo "};" >> "$MASTER_CFG"

    ### Slave Forward
    if [ "$ENABLE_SLAVE" == "true" ]; then
        echo "zone \"$DOMAIN\" IN {" >> "$SLAVE_CFG"
        echo "    type slave;" >> "$SLAVE_CFG"
        echo "    masters { $DNS_MASTER_IP; };" >> "$SLAVE_CFG"
        echo "    file \"slaves/${DOMAIN}.zone\";" >> "$SLAVE_CFG"
        echo "};" >> "$SLAVE_CFG"
    fi

    ### Reverse Zone (Check duplicates)
    if [[ "$PROCESSED_REV_ZONES" != *"$REV_ZONE"* ]]; then
        ### Master Reverse
        echo "zone \"$REV_ZONE\" IN {" >> "$MASTER_CFG"
        echo "    type master;" >> "$MASTER_CFG"
        echo "    file \"${REV_ZONE}.zone\";" >> "$MASTER_CFG"
        echo "    allow-update { none; };" >> "$MASTER_CFG"
        [ "$ENABLE_SLAVE" == "true" ] && echo "    allow-transfer { $DNS_SLAVE_IP; };" >> "$MASTER_CFG"
        echo "};" >> "$MASTER_CFG"

        ### Slave Reverse
        if [ "$ENABLE_SLAVE" == "true" ]; then
            echo "zone \"$REV_ZONE\" IN {" >> "$SLAVE_CFG"
            echo "    type slave;" >> "$SLAVE_CFG"
            echo "    masters { $DNS_MASTER_IP; };" >> "$SLAVE_CFG"
            echo "    file \"slaves/${REV_ZONE}.zone\";" >> "$SLAVE_CFG"
            echo "};" >> "$SLAVE_CFG"
        fi
        PROCESSED_REV_ZONES="$PROCESSED_REV_ZONES $REV_ZONE"
    fi
done

echo "    - Zone files created with separators."

### ==============================================================================
### 3. Generate Smart 'install.sh'
### ==============================================================================
echo ">>> [2/2] Generating installation script..."

INSTALL_SCRIPT="$OUTPUT_DIR/install.sh"

cat > "$INSTALL_SCRIPT" <<EOF
#!/bin/bash

### Auto-generated DNS Installation Script
### Strategy: STRICT RESET using .orig files

CONF_MASTER_IP="${DNS_MASTER_IP}"
CONF_SLAVE_IP="${DNS_SLAVE_IP}"

BIND_ACL_LISTEN="${BIND_ACL_LISTEN}"
BIND_ACL_QUERY="${BIND_ACL_QUERY}"
BIND_RECURSION="${BIND_RECURSION}"
BIND_FORWARDERS="${BIND_FORWARDERS}"

SOURCE_DIR="\$(dirname "\$(realpath "\$0")")"
CONF_DIR="/etc"
NAMED_CONF="\${CONF_DIR}/named.conf"
RFC1912_ZONES="\${CONF_DIR}/named.rfc1912.zones"
ZONE_DIR="/var/named"
SLAVE_ZONE_DIR="/var/named/slaves"

### ======================================================================
### 1. Robust Role Detection
### ======================================================================
echo ">>> [Install] Detecting Server Role..."

if [ "\$1" == "MASTER" ] || [ "\$1" == "SLAVE" ]; then
    MY_ROLE="\$1"
    echo "    - Manual Override Detected: \$MY_ROLE"
else
    MY_ROLE="UNKNOWN"
    CURRENT_IPS=\$(hostname -I)

    for IP in \$CURRENT_IPS; do
        if [ "\$IP" == "\$CONF_MASTER_IP" ]; then
            MY_ROLE="MASTER"
            break
        elif [ -n "\$CONF_SLAVE_IP" ] && [ "\$IP" == "\$CONF_SLAVE_IP" ]; then
            MY_ROLE="SLAVE"
            break
        fi
    done
fi

if [ "\$MY_ROLE" == "UNKNOWN" ]; then
    echo "Error: Could not determine server role."
    echo "       Server IPs: \$(hostname -I)"
    echo "       Expected Master: \$CONF_MASTER_IP"
    echo "       Expected Slave : \$CONF_SLAVE_IP"
    echo "Usage: ./install.sh MASTER (or SLAVE)"
    exit 1
fi

if [ "\$MY_ROLE" == "MASTER" ]; then
    TARGET_CONF_FILE="named.master.conf"
else
    TARGET_CONF_FILE="named.slave.conf"
fi
echo "    - Role: \$MY_ROLE"

### ======================================================================
### 2. Install BIND (if missing)
### ======================================================================
if ! rpm -q bind > /dev/null 2>&1; then
    echo ">>> [Install] Installing BIND..."
    dnf install -y bind bind-utils
else
    echo ">>> [Install] BIND is already installed."
fi

### ======================================================================
### 3. Prepare Config Files (.orig Strategy)
### ======================================================================
echo ">>> [Install] Resetting Configuration Files from Originals..."

if [ ! -f "\${NAMED_CONF}.orig" ]; then
    echo "    - [INFO] Creating first-time backup: named.conf.orig"
    cp -p "\$NAMED_CONF" "\${NAMED_CONF}.orig"
fi
echo "    - Restoring named.conf from .orig"
cp -f "\${NAMED_CONF}.orig" "\$NAMED_CONF"


if [ ! -f "\${RFC1912_ZONES}.orig" ]; then
    echo "    - [INFO] Creating first-time backup: named.rfc1912.zones.orig"
    cp -p "\$RFC1912_ZONES" "\${RFC1912_ZONES}.orig"
fi

### Sanitize .orig (if it was already polluted) before restoring
if grep -q "cloudpang.lan" "\${RFC1912_ZONES}.orig"; then
    echo "    - [WARNING] Your .orig file seems polluted. Attempting cleanup..."
    cp -f "\${RFC1912_ZONES}.orig" "\$RFC1912_ZONES"

    ### Range delete for known zones
    sed -i '/zone "cloudpang.lan"/,/};/d' "\$RFC1912_ZONES"
    sed -i '/zone "ocp4-hub.cloudpang.lan"/,/};/d' "\$RFC1912_ZONES"
    sed -i '/zone "ocp4-mgc01.cloudpang.lan"/,/};/d' "\$RFC1912_ZONES"
    sed -i '/zone "120.16.172.in-addr.arpa"/,/};/d' "\$RFC1912_ZONES"
    ### Remove include lines
    sed -i '/include "\/etc\/named\/named.master.conf";/d' "\$RFC1912_ZONES"
    sed -i '/include "\/etc\/named\/named.slave.conf";/d' "\$RFC1912_ZONES"
else
    echo "    - Restoring named.rfc1912.zones from clean .orig"
    cp -f "\${RFC1912_ZONES}.orig" "\$RFC1912_ZONES"
fi


### ======================================================================
### 4. Apply Configuration Options
### ======================================================================
echo ">>> [Install] Applying options to named.conf..."

sed -i "s|listen-on port 53 { 127.0.0.1; };|listen-on port 53 { \${BIND_ACL_LISTEN} };|g" "\$NAMED_CONF"
sed -i "s|allow-query     { localhost; };|allow-query     { \${BIND_ACL_QUERY} };|g" "\$NAMED_CONF"

sed -i '/forwarders {/d' "\$NAMED_CONF"
if [ -n "\$BIND_FORWARDERS" ]; then
    REPL="recursion \${BIND_RECURSION};\\\\n\\\\tforwarders { \${BIND_FORWARDERS} };"
else
    REPL="recursion \${BIND_RECURSION};"
fi
sed -i "s|recursion .*;|\$REPL|g" "\$NAMED_CONF"


### ======================================================================
### 5. Deploy Files
### ======================================================================
echo ">>> [Install] Deploying Zone & Config files..."

DEST_CONF="/etc/named/\$TARGET_CONF_FILE"
cp -f "\$SOURCE_DIR/\$TARGET_CONF_FILE" "\$DEST_CONF"
chown root:named "\$DEST_CONF"
chmod 640 "\$DEST_CONF"

if [ "\$MY_ROLE" == "MASTER" ]; then
    cp -f "\$SOURCE_DIR"/*.zone "\$ZONE_DIR/"
    chown root:named "\$ZONE_DIR"/*.zone
    chmod 640 "\$ZONE_DIR"/*.zone
elif [ "\$MY_ROLE" == "SLAVE" ]; then
    if [ ! -d "\$SLAVE_ZONE_DIR" ]; then
        mkdir -p "\$SLAVE_ZONE_DIR"
    fi
    chown named:named "\$SLAVE_ZONE_DIR"
    chmod 770 "\$SLAVE_ZONE_DIR"
fi

### ======================================================================
### 6. Finalize & Restart
### ======================================================================
echo ">>> [Install] Linking Configuration..."

echo "" >> "\$RFC1912_ZONES"
echo "include \"\$DEST_CONF\";" >> "\$RFC1912_ZONES"

echo ">>> [Install] Verifying and Restarting..."
named-checkconf "\$NAMED_CONF"
if [ \$? -eq 0 ]; then
    systemctl enable named --now > /dev/null 2>&1
    systemctl restart named
    echo "SUCCESS: Configuration applied cleanly."
else
    echo "Error: Syntax check failed."
    exit 1
fi
EOF

### Make the generated installer executable
chmod +x "$INSTALL_SCRIPT"

echo "------------------------------------------------------------"
echo ">>> Generation Complete!"
echo "    Output Directory : $OUTPUT_DIR"
echo "------------------------------------------------------------"
echo "Usage:"
echo "  1. cd $OUTPUT_DIR"
echo "  2. Review generated Zone files & Configs (Optional)"
echo "  3. Run './install.sh'"
echo "------------------------------------------------------------"
echo ""