#!/bin/bash

# Enable strict mode
set -euo pipefail

### ==============================================================================
### 0. Default Configuration & Variables
### ==============================================================================

BASE_CERT_DIR="$PWD/custom-certs"
DEFAULT_DAYS_DOMAIN=3650
DEFAULT_ROOT_CA_CN="RootCA"

# Default Subject DN Info
CERT_C="KR"
CERT_ST="Seoul"
CERT_L="Gangnam"
CERT_O="MyCompany"
CERT_OU="DevOpsTeam"

ROOT_CA_DIR="$BASE_CERT_DIR/rootCA"
DOMAIN_CERT_DIR="$BASE_CERT_DIR/domain_certs"

### Initialize Variables
DOMAIN=""
DAYS_DOMAIN=""
ROOT_CA_CN=""

### ==============================================================================
### 1. Helper Functions
### ==============================================================================

usage() {
    echo "Usage: $0 [ -d domain ] [ -n root_ca_cn ] [ -e days ]"
    echo "  -d : Domain name (e.g., example.com)"
    echo "  -n : Root CA Common Name (default: RootCA)"
    echo "  -e : Validity in days (default: 3650)"
    exit 1
}

check_deps() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: 'openssl' is not installed."
        exit 1
    fi
}

### ==============================================================================
### 2. Parse Arguments
### ==============================================================================

while getopts "d:n:e:h" opt; do
    case ${opt} in
        d) DOMAIN=$OPTARG ;;
        n) ROOT_CA_CN=$OPTARG ;;
        e) DAYS_DOMAIN=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

### ==============================================================================
### 3. Interactive Input (Logic Improved)
### ==============================================================================

# 1. Domain Input
if [ -z "$DOMAIN" ]; then
    read -p "Enter domain name (e.g., example.com): " INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-example.com}"
fi

# 2. Root CA CN Input
ROOT_CA_KEY="$ROOT_CA_DIR/rootCA.key"
ROOT_CA_CRT="$ROOT_CA_DIR/rootCA.crt"

if [ -f "$ROOT_CA_KEY" ] && [ -f "$ROOT_CA_CRT" ]; then
    echo ">> [INFO] Existing Root CA found at '$ROOT_CA_DIR'. Skipping CN input."
else
    if [ -z "$ROOT_CA_CN" ]; then
        read -p "Enter Root CA CN (default: $DEFAULT_ROOT_CA_CN): " INPUT_CN
        ROOT_CA_CN="${INPUT_CN:-$DEFAULT_ROOT_CA_CN}"
    fi
fi

# 3. Validity Days Input
if [ -z "$DAYS_DOMAIN" ]; then
    read -p "Enter validity days (default: $DEFAULT_DAYS_DOMAIN): " INPUT_DAYS
    DAYS_DOMAIN="${INPUT_DAYS:-$DEFAULT_DAYS_DOMAIN}"
fi

### Validation
if ! echo "$DOMAIN" | grep -qE '^(\*\.)?[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+$'; then
    echo "ERROR: Invalid domain format: '$DOMAIN'"
    exit 1
fi

if ! [[ "$DAYS_DOMAIN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Validity days must be a number."
    exit 1
fi

FILE_DOMAIN=$(echo "$DOMAIN" | sed 's/^\*/wildcard/')
DAYS_ROOT_CA=$((DAYS_DOMAIN + 1825))

### Create Directories
mkdir -p "$ROOT_CA_DIR" "$DOMAIN_CERT_DIR"

### ==============================================================================
### 4. Create Root CA
### ==============================================================================

create_root_ca() {
    local key_file="$ROOT_CA_DIR/rootCA.key"
    local crt_file="$ROOT_CA_DIR/rootCA.crt"

    if [ -f "$key_file" ] && [ -f "$crt_file" ]; then
        echo ">> [Check] Using existing Root CA."

        local current_cn
        current_cn=$(openssl x509 -in "$crt_file" -noout -subject -nameopt multiline | grep commonName | awk '{$1=$1; print}')
        echo "   -> CN: $current_cn"
        return
    fi

    echo ">> Creating NEW Root CA ($ROOT_CA_CN)..."

    openssl genrsa -out "$key_file" 4096 2>/dev/null
    chmod 600 "$key_file"

    openssl req -x509 -new -nodes -key "$key_file" \
        -sha256 -days "$DAYS_ROOT_CA" -out "$crt_file" \
        -subj "/C=$CERT_C/ST=$CERT_ST/L=$CERT_L/O=$CERT_O/OU=$CERT_OU/CN=$ROOT_CA_CN" 2>/dev/null

    echo "   [OK] Root CA created."
}

### ==============================================================================
### 5. Create Domain Certificate
### ==============================================================================

create_domain_cert() {
    local key_file="$DOMAIN_CERT_DIR/$FILE_DOMAIN.key"
    local csr_file="$DOMAIN_CERT_DIR/$FILE_DOMAIN.csr"
    local crt_file="$DOMAIN_CERT_DIR/$FILE_DOMAIN.crt"
    local conf_file="$DOMAIN_CERT_DIR/$FILE_DOMAIN.conf"

    echo ">> Creating Certificate for $DOMAIN..."

    # Create OpenSSL Config
    cat > "$conf_file" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = $CERT_C
ST = $CERT_ST
L = $CERT_L
O = $CERT_O
OU = $CERT_OU
CN = $DOMAIN

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF

    # Generate Key
    openssl genrsa -out "$key_file" 2048 2>/dev/null
    chmod 600 "$key_file"

    # Generate CSR
    openssl req -new -key "$key_file" -out "$csr_file" -config "$conf_file" 2>/dev/null

    # Sign Certificate
    openssl x509 -req -in "$csr_file" \
        -CA "$ROOT_CA_DIR/rootCA.crt" -CAkey "$ROOT_CA_DIR/rootCA.key" \
        -CAcreateserial -out "$crt_file" \
        -days "$DAYS_DOMAIN" -sha256 \
        -extfile "$conf_file" -extensions req_ext 2>/dev/null

    # Cleanup
    rm -f "$csr_file" "$conf_file"

    echo "   [OK] Certificate created at: $crt_file"
}

### ==============================================================================
### 6. Verify
### ==============================================================================

verify_cert() {
    local crt_file="$DOMAIN_CERT_DIR/$FILE_DOMAIN.crt"

    echo ">> Verifying Certificate..."
    if openssl x509 -in "$crt_file" -text -noout | grep -q "DNS:$DOMAIN"; then
        echo "   [SUCCESS] Certificate implies SAN: $DOMAIN"
    else
        echo "   [FAIL] SAN verification failed."
        exit 1
    fi
}

### Main Execution Flow
check_deps
create_root_ca
create_domain_cert
verify_cert