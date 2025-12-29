#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. HAProxy Statistics Configuration
### HAProxy Statistics Listen Address
### Formats allowed:
###   - "IP:PORT" (e.g., "172.16.120.29:1936")
###   - "IP"      (e.g., "172.16.120.29") -> Defaults to Port 1936
###   - "PORT"    (e.g., "1936")          -> Defaults to IP *
###   - ""        (Empty)                 -> Defaults to *:1936
LB_STATS_LISTEN="172.16.120.29"

### 2. Bind Configuration
### ACL for 'listen-on' directive (For API/Ingress/Gateway)
### IP Address ONLY (Do NOT include port)
BIND_ACL_LISTEN="172.16.120.29"

### 3. Node Definitions
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

### 4. Output Settings
OUTPUT_DIR="./haproxy-dist"
CONFIG_FILE="$OUTPUT_DIR/haproxy.cfg"
INSTALL_SCRIPT="$OUTPUT_DIR/install.sh"


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

### 1. Prerequisites & Validation
log_info "=== Prerequisites & Validation"

### Check Array Validity
if [ ${#MASTER_NODES[@]} -eq 0 ]; then
    log_error "MASTER_NODES array is empty."
    exit 1
fi

if [ ${#INFRA_NODES[@]} -eq 0 ]; then
    log_error "INFRA_NODES array is empty."
    exit 1
fi

### Check IP Format
if [[ "$BIND_ACL_LISTEN" =~ : ]]; then
    log_error "Invalid format for BIND_ACL_LISTEN: '$BIND_ACL_LISTEN'"
    log_info  "This variable must contain an IP address ONLY."
    exit 1
fi

log_info "--- Configuration validation passed."

### 2. Output Directory Initialization
log_info "=== Output Directory Initialization"
log_info "--- Preparing output directory: $OUTPUT_DIR"

execute rm -rf "$OUTPUT_DIR"
execute mkdir -p "$OUTPUT_DIR"

### 3. Parse Listen Variables
log_info "=== Parameter Parsing"

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

log_info "    Stats Bind IP : $STATS_BIND_IP"
log_info "    Stats Port    : $STATS_BIND_PORT"
log_info "    Service Bind  : $BIND_ACL_LISTEN"
if [ ${#GATEWAY_API_PORTS[@]} -gt 0 ]; then
    log_info "    Gateway Ports : ${GATEWAY_API_PORTS[*]}"
fi

### 4. Artifact Generation (haproxy.cfg)
log_info "=== Artifact Generation"
log_info "--- Creating configuration file: haproxy.cfg"

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

### Dynamic Generation for Gateway API / Extra Ports
if [ ${#GATEWAY_API_PORTS[@]} -gt 0 ]; then
    log_info "--- Adding Gateway API Ports..."

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

log_info "--- Configuration file created successfully."

### 5. Installer Generation
log_info "=== Installer Generation"
log_info "--- Creating 'install.sh'..."

cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash

### ==============================================================================
### Global Configuration
### ==============================================================================

### 1. HAProxy Settings
STATS_PORT="${STATS_BIND_PORT}"

### 2. File Paths
SOURCE_DIR="\$(dirname "\$(realpath "\$0")")"
TARGET_CONF="/etc/haproxy/haproxy.cfg"
SOURCE_CONF="\${SOURCE_DIR}/haproxy.cfg"

### 3. Service Info
SERVICE_NAME="haproxy"

### 4. Port Configuration
BASE_PORTS="80 443 6443 22623 \${STATS_PORT}"
GATEWAY_PORTS="${GATEWAY_API_PORTS[*]}"
ALL_PORTS="\${BASE_PORTS} \${GATEWAY_PORTS}"


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

### 1. Prerequisites Check
log_info "=== Prerequisites Check"

if [[ \$EUID -ne 0 ]]; then
    log_error "Run as root."
    exit 1
fi

if ! rpm -q haproxy > /dev/null 2>&1; then
    log_error "HAProxy is NOT installed."
    log_info  "Please install HAProxy manually using: dnf install -y haproxy policycoreutils-python-utils net-tools"
    exit 1
else
    log_info "--- HAProxy installed. Proceeding..."
fi

if [[ ! -f "\$SOURCE_CONF" ]]; then
    log_error "Could not find 'haproxy.cfg' in the current directory."
    exit 1
fi

### 2. Configuration Setup
log_info "=== Configuration Setup"
log_info "--- Backing up existing configuration..."

if [[ ! -f "\${TARGET_CONF}.orig" ]]; then
    if [[ -f "\$TARGET_CONF" ]]; then
        execute cp -p "\$TARGET_CONF" "\${TARGET_CONF}.orig"
    else
        execute touch "\${TARGET_CONF}.orig"
    fi
fi

log_info "--- Deploying new configuration..."
execute cp -f "\$SOURCE_CONF" "\$TARGET_CONF"

### 3. Security Settings (SELinux & Firewall)
log_info "=== Security Settings"

log_info "--- Restoring SELinux Context..."
if [[ -f "\${TARGET_CONF}.orig" ]]; then
    execute chcon --reference="\${TARGET_CONF}.orig" "\$TARGET_CONF"
else
    execute restorecon -v "\$TARGET_CONF"
fi

log_info "--- Configuring Ports (SELinux & Firewall)..."

add_port() {
    local port=\$1
    # Check if port is already defined in SELinux to avoid error
    if ! semanage port -l | grep -q "\$port"; then
         execute semanage port -a -t http_port_t -p tcp \$port 2>/dev/null || true
    fi
    execute firewall-cmd --permanent --add-port=\${port}/tcp --zone=public > /dev/null 2>&1
}

for port in \${ALL_PORTS}; do
    add_port \$port
done

execute firewall-cmd --reload > /dev/null

### 4. Service Management
log_info "=== Service Management"
log_info "--- Validating configuration..."

if ! haproxy -c -f "\$TARGET_CONF" >/dev/null 2>&1; then
    log_error "Configuration syntax check failed!"
    exit 1
fi

log_info "--- Restarting HAProxy service..."
execute systemctl enable \$SERVICE_NAME --now
execute systemctl restart \$SERVICE_NAME

SERVER_IP=\$(hostname -I | awk '{print \$1}')

### 5. Completion
log_info "----------------------------------------------------------------"
log_info " [SUCCESS] HAProxy Installation Complete"
log_info "----------------------------------------------------------------"
log_info "  Service  : \$SERVICE_NAME (Restarted)"
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