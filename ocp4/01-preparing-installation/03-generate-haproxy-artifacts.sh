#!/bin/bash

### ====================================================
### [HAProxy Deployment Generator]
### This script generates 'haproxy.cfg' and 'install.sh'
### Includes support for OCP 4.19+ Gateway API Ports
### ====================================================

### ----------------------------------------------------
### [1. User Configuration Variables]
### ----------------------------------------------------

### HAProxy Statistics Listen Address
### Formats allowed:
###   - "IP:PORT" (e.g., "172.16.120.29:1936")
###   - "IP"      (e.g., "172.16.120.29") -> Defaults to Port 1936
###   - "PORT"    (e.g., "1936")          -> Defaults to IP *
###   - ""        (Empty)                 -> Defaults to *:1936
LB_STATS_LISTEN="172.16.120.29"

### ACL for 'listen-on' directive (For API/Ingress/Gateway)
### IP Address ONLY (Do NOT include port)
BIND_ACL_LISTEN="172.16.120.29"

### Master Nodes (API: 6443, MCS: 22623)
MASTER_NODES=(
    "172.16.120.111"
    "172.16.120.112"
    "172.16.120.113"
    )

### Infra/Router Nodes (Ingress: 80, 443 & Gateway API)
INFRA_NODES=(
    "172.16.120.121"
    "172.16.120.122"
    "172.16.120.123"
    )

### Additional Gateway API Ports
### Define ports used by Gateway API or other LoadBalancer services here.
### The script will automatically create listeners for these ports forwarding to Infra Nodes.
### Example: GATEWAY_API_PORTS=("8080" "8443" "9090")
GATEWAY_API_PORTS=()

### Output Directory Configuration
OUTPUT_DIR="./haproxy-dist"
CONFIG_FILE="$OUTPUT_DIR/haproxy.cfg"
INSTALL_SCRIPT="$OUTPUT_DIR/install.sh"

### ----------------------------------------------------
### [2. Pre-flight Validation]
### ----------------------------------------------------
echo ">>> [Validation] Checking configuration variables..."

if [ ${#MASTER_NODES[@]} -eq 0 ]; then
    echo ">>> [ERROR] MASTER_NODES array is empty."
    exit 1
fi

if [ ${#INFRA_NODES[@]} -eq 0 ]; then
    echo ">>> [ERROR] INFRA_NODES array is empty."
    exit 1
fi

if [[ "$BIND_ACL_LISTEN" =~ : ]]; then
    echo ">>> [ERROR] Invalid format for BIND_ACL_LISTEN: '$BIND_ACL_LISTEN'"
    echo "    This variable must contain an IP address ONLY."
    exit 1
fi

echo "    - Configuration looks good."

### ----------------------------------------------------
### [3. Initialize Output Directory]
### ----------------------------------------------------
echo ">>> [Generator] Preparing output directory: $OUTPUT_DIR"

if [ -d "$OUTPUT_DIR" ]; then
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

### ----------------------------------------------------
### [4. Parse Listen Variables]
### ----------------------------------------------------
DEFAULT_STATS_PORT="1936"

if [[ -z "$LB_STATS_LISTEN" ]]; then
    STATS_BIND_IP="*"
    STATS_BIND_FULL="*:${DEFAULT_STATS_PORT}"
    STATS_BIND_PORT="${DEFAULT_STATS_PORT}"
elif [[ "$LB_STATS_LISTEN" =~ : ]]; then
    STATS_BIND_IP="${LB_STATS_LISTEN%:*}"
    STATS_BIND_FULL="$LB_STATS_LISTEN"
    STATS_BIND_PORT="${LB_STATS_LISTEN##*:}"
elif [[ "$LB_STATS_LISTEN" =~ ^[0-9]+$ ]]; then
    STATS_BIND_IP="*"
    STATS_BIND_FULL="*:$LB_STATS_LISTEN"
    STATS_BIND_PORT="$LB_STATS_LISTEN"
else
    STATS_BIND_IP="$LB_STATS_LISTEN"
    STATS_BIND_FULL="${LB_STATS_LISTEN}:${DEFAULT_STATS_PORT}"
    STATS_BIND_PORT="${DEFAULT_STATS_PORT}"
fi

if [[ -z "$BIND_ACL_LISTEN" ]]; then
    BIND_ACL_LISTEN="*"
fi

echo "    - Stats Bind IP : $STATS_BIND_IP"
echo "    - Stats Port    : $STATS_BIND_PORT"
echo "    - Service Bind  : $BIND_ACL_LISTEN"
if [ ${#GATEWAY_API_PORTS[@]} -gt 0 ]; then
    echo "    - Gateway Ports : ${GATEWAY_API_PORTS[*]}"
fi

### ----------------------------------------------------
### [5. Generate haproxy.cfg]
### ----------------------------------------------------
echo ">>> [Generator] Creating configuration file: haproxy.cfg"

cat <<EOF > "$CONFIG_FILE"
global
  log         127.0.0.1 local2
  pidfile     /var/run/haproxy.pid
  maxconn     4000
  daemon

defaults
  mode                    http
  log                     global
  option                  dontlognull
  option http-server-close
  option                  redispatch
  retries                 3
  timeout http-request    10s
  timeout queue           1m
  timeout connect         10s
  timeout client          1m
  timeout server          1m
  timeout http-keep-alive 10s
  timeout check           10s
  maxconn                 3000

### ---------------------------------------------------------------------
### HAProxy Statistics Page
### ---------------------------------------------------------------------
frontend stats
  bind ${STATS_BIND_FULL}
  mode            http
  log             global
  maxconn 10
  stats enable
  stats hide-version
  stats refresh 30s
  stats show-node
  stats show-desc Stats for OCP4 LB
  stats auth admin:ocp4
  stats uri /stats

### ---------------------------------------------------------------------
### OpenShift API Server (6443)
### ---------------------------------------------------------------------
listen api-server-6443
  bind ${BIND_ACL_LISTEN}:6443
  mode tcp
  balance source
EOF

### Loop: Master Nodes (API)
i=1
for ip in "${MASTER_NODES[@]}"; do
    name=$(printf "master-%02d" $i)
    printf "  server %-16s %-22s check inter 1s\n" "$name" "$ip:6443" >> "$CONFIG_FILE"
    ((i++))
done

cat <<EOF >> "$CONFIG_FILE"

### ---------------------------------------------------------------------
### Machine Config Server (22623)
### ---------------------------------------------------------------------
listen machine-config-server-22623
  bind ${BIND_ACL_LISTEN}:22623
  mode tcp
  balance source
EOF

### Loop: Master Nodes (MCS)
i=1
for ip in "${MASTER_NODES[@]}"; do
    name=$(printf "master-%02d" $i)
    printf "  server %-16s %-22s check inter 1s\n" "$name" "$ip:22623" >> "$CONFIG_FILE"
    ((i++))
done

cat <<EOF >> "$CONFIG_FILE"

### ---------------------------------------------------------------------
### Ingress Router (80)
### Traffic -> 80, Health Check -> 1936 (Router Pod)
### ---------------------------------------------------------------------
listen ingress-router-80
  bind ${BIND_ACL_LISTEN}:80
  mode tcp
  balance source
EOF

### Loop: Infra Nodes (80)
i=1
for ip in "${INFRA_NODES[@]}"; do
    name=$(printf "router-%02d" $i)
    printf "  server %-16s %-22s check port 1936 inter 1s\n" "$name" "$ip:80" >> "$CONFIG_FILE"
    ((i++))
done

cat <<EOF >> "$CONFIG_FILE"

### ---------------------------------------------------------------------
### Ingress Router (443)
### Traffic -> 443, Health Check -> 1936 (Router Pod)
### ---------------------------------------------------------------------
listen ingress-router-443
  bind ${BIND_ACL_LISTEN}:443
  mode tcp
  balance source
EOF

### Loop: Infra Nodes (443)
i=1
for ip in "${INFRA_NODES[@]}"; do
    name=$(printf "router-%02d" $i)
    printf "  server %-16s %-22s check port 1936 inter 1s\n" "$name" "$ip:443" >> "$CONFIG_FILE"
    ((i++))
done

### =====================================================================
### Dynamic Generation for Gateway API / Extra Ports
### =====================================================================
if [ ${#GATEWAY_API_PORTS[@]} -gt 0 ]; then
    echo ">>> [Generator] Adding Gateway API Ports: ${GATEWAY_API_PORTS[*]}"

    for port in "${GATEWAY_API_PORTS[@]}"; do
cat <<EOF >> "$CONFIG_FILE"

### ---------------------------------------------------------------------
### Gateway API / Custom Service (${port})
### ---------------------------------------------------------------------
listen gateway-api-${port}
  bind ${BIND_ACL_LISTEN}:${port}
  mode tcp
  balance source
EOF
        j=1
        for ip in "${INFRA_NODES[@]}"; do
            name=$(printf "router-%02d" $j)
            printf "  server %-16s %-22s check inter 1s\n" "$name" "$ip:$port" >> "$CONFIG_FILE"
            ((j++))
        done
    done
fi

### ----------------------------------------------------
### [6. Generate install.sh]
### ----------------------------------------------------
echo ">>> [Generator] Creating installation script: install.sh"

cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash

### HAProxy Installation Script
### Generated by create_deployment.sh

SOURCE_DIR="\$(dirname "\$(realpath "\$0")")"
TARGET_CONF="/etc/haproxy/haproxy.cfg"
SOURCE_CONF="\${SOURCE_DIR}/haproxy.cfg"
STATS_PORT=${STATS_BIND_PORT}

### Prepare Port List for Firewall (Base Ports + Gateway Ports)
BASE_PORTS="80 443 6443 22623 \${STATS_PORT}"
GATEWAY_PORTS="${GATEWAY_API_PORTS[*]}"
ALL_PORTS="\${BASE_PORTS} \${GATEWAY_PORTS}"

### ======================================================================
### 1. Install HAProxy (if missing)
### ======================================================================
if ! rpm -q haproxy > /dev/null 2>&1; then
    echo ">>> [Install] Installing HAProxy & Required Utils..."
    dnf install -y haproxy policycoreutils-python-utils net-tools
else
    echo ">>> [Install] HAProxy is already installed."
fi

### ======================================================================
### 2. Deploy Config Files (.orig Strategy)
### ======================================================================
echo ">>> [Install] Resetting Configuration..."

if [ ! -f "\${TARGET_CONF}.orig" ]; then
    echo "    - [INFO] Creating first-time backup: haproxy.cfg.orig"
    if [ -f "\$TARGET_CONF" ]; then
        cp -p "\$TARGET_CONF" "\${TARGET_CONF}.orig"
    else
        touch "\${TARGET_CONF}.orig"
    fi
fi

if [ ! -f "\$SOURCE_CONF" ]; then
    echo "ERROR: Could not find 'haproxy.cfg' in the current directory."
    exit 1
fi

echo "    - Deploying new haproxy.cfg from source..."
cp -f "\$SOURCE_CONF" "\$TARGET_CONF"

### ======================================================================
### 3. Security Settings (SELinux & Firewall)
### ======================================================================
echo ">>> [Install] Applying Security Settings..."

### Restore SELinux Context
if [ -f "\${TARGET_CONF}.orig" ]; then
    chcon --reference="\${TARGET_CONF}.orig" "\$TARGET_CONF"
else
    restorecon -v "\$TARGET_CONF"
fi

### Allow Ports in SELinux & Firewall
echo "    - Configuring Ports (SELinux & Firewall)..."

### Helper function to add ports safely
add_port() {
    local port=\$1
    semanage port -a -t http_port_t -p tcp \$port 2>/dev/null || true
    firewall-cmd --permanent --add-port=\${port}/tcp --zone=public > /dev/null 2>&1
}

# Add standard & stats ports
add_port 1936
add_port \${STATS_PORT}
add_port 6443
add_port 22623
# Note: 80/443 are usually already allowed, but adding ensures safety
add_port 80
add_port 443

# Add Gateway API Ports if any
for gw_port in ${GATEWAY_API_PORTS[*]}; do
    add_port \$gw_port
done

firewall-cmd --reload > /dev/null

### ======================================================================
### 4. Restart Service
### ======================================================================
echo ">>> [Install] Validating and Restarting..."

if haproxy -c -f "\$TARGET_CONF"; then
    systemctl enable haproxy --now
    systemctl restart haproxy

    SERVER_IP=\$(hostname -I | awk '{print \$1}')
    echo "SUCCESS: HAProxy is running."
    echo "Stats URL: http://\${SERVER_IP}:\${STATS_PORT}/stats"
    echo "Ports    : \${ALL_PORTS}"
else
    echo "ERROR: Configuration syntax check failed!"
    exit 1
fi
EOF

chmod +x "$INSTALL_SCRIPT"

echo "------------------------------------------------------------"
echo ">>> Generation Complete!"
echo "    Output Directory : $OUTPUT_DIR"
echo "------------------------------------------------------------"
echo "Usage:"
echo "  1. cd $OUTPUT_DIR"
echo "  2. Review 'haproxy.cfg'"
echo "  3. Run './install.sh'"
echo "------------------------------------------------------------"
echo ""