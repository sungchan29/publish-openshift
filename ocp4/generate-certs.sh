#!/bin/bash

# Enable strict mode
set -euo pipefail

### Set variables
BASE_CERT_DIR="/root/ocp4/certs"
DEFAULT_DAYS_DOMAIN=3650  # Default: 10 years for domain cert

ROOT_CA_DIR="$BASE_CERT_DIR/rootCA"
DOMAIN_CERT_DIR="$BASE_CERT_DIR/domain_certs"

### Validate commands
if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: 'openssl' is not installed. Exiting..."
    exit 1
fi

### Check if directories exist, create them if they don't
mkdir -p "$ROOT_CA_DIR" || { echo "ERROR: Failed to create '$ROOT_CA_DIR'. Exiting..."; exit 1; }
mkdir -p "$DOMAIN_CERT_DIR" || { echo "ERROR: Failed to create '$DOMAIN_CERT_DIR'. Exiting..."; exit 1; }

### Prompt for domain name
read -p "Enter domain name (e.g., example.com or *.apps.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "No domain provided. Using default: example.com"
    DOMAIN="example.com"
fi

### Validate domain format
if ! echo "$DOMAIN" | grep -qE '^(\*\.)?[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+$'; then
    echo "ERROR: Invalid domain format: '$DOMAIN'. Exiting..."
    exit 1
fi

### Replace '*' with 'wildcard' for file naming
FILE_DOMAIN=$(echo "$DOMAIN" | sed 's/^\*/wildcard/')

### Prompt for domain certificate validity period
read -p "Enter domain certificate validity in days (default is $DEFAULT_DAYS_DOMAIN days / 10 years): " DAYS_DOMAIN
if [ -z "$DAYS_DOMAIN" ]; then
    DAYS_DOMAIN=$DEFAULT_DAYS_DOMAIN
    echo "No validity period provided. Using default: $DAYS_DOMAIN days"
fi

### Validate DAYS_DOMAIN is a number
if ! [[ "$DAYS_DOMAIN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Validity period '$DAYS_DOMAIN' must be a number. Exiting..."
    exit 1
fi

### Set Root CA validity to domain validity + 5 years (1825 days)
DAYS_ROOT_CA=$((DAYS_DOMAIN + 1825))
if [ "$DAYS_ROOT_CA" -le "$DAYS_DOMAIN" ]; then
    echo "ERROR: Root CA validity ($DAYS_ROOT_CA days) must be greater than domain validity ($DAYS_DOMAIN days). Exiting..."
    exit 1
fi
echo "Root CA validity set to: $DAYS_ROOT_CA days"

### Function to create root CA if it doesn't exist
create_root_ca() {
    if [ ! -f "$ROOT_CA_DIR/rootCA.key" ] || [ ! -f "$ROOT_CA_DIR/rootCA.crt" ]; then
        echo "Creating Root CA..."
        # Generate Root CA private key
        openssl genrsa -out "$ROOT_CA_DIR/rootCA.key" 4096 2>/dev/null || {
            echo "ERROR: Failed to generate Root CA key. Exiting..."
            exit 1
        }
        # Generate Root CA certificate
        openssl req -x509 -new -nodes -key "$ROOT_CA_DIR/rootCA.key" \
            -sha256 -days "$DAYS_ROOT_CA" -out "$ROOT_CA_DIR/rootCA.crt" \
            -subj "/C=KR/ST=State/L=City/O=Organization/OU=Unit/CN=RootCA" 2>/dev/null || {
            echo "ERROR: Failed to generate Root CA certificate. Exiting..."
            exit 1
        }
        echo "Root CA created at $ROOT_CA_DIR/rootCA.crt"
    else
        echo "Root CA already exists at $ROOT_CA_DIR, skipping creation."
    fi
}

### Function to create domain certificate
create_domain_cert() {
    echo "Creating domain certificate for $DOMAIN..."

    # Create config file for SAN
    cat > "$DOMAIN_CERT_DIR/$FILE_DOMAIN.conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = KR
ST = State
L = City
O = Organization
OU = Unit
CN = $DOMAIN

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF

    # Generate domain private key
    openssl genrsa -out "$DOMAIN_CERT_DIR/$FILE_DOMAIN.key" 2048 2>/dev/null || {
        echo "ERROR: Failed to generate domain key. Exiting..."
        exit 1
    }

    # Generate CSR (Certificate Signing Request)
    openssl req -new -key "$DOMAIN_CERT_DIR/$FILE_DOMAIN.key" \
        -out "$DOMAIN_CERT_DIR/$FILE_DOMAIN.csr" \
        -config "$DOMAIN_CERT_DIR/$FILE_DOMAIN.conf" 2>/dev/null || {
        echo "ERROR: Failed to generate CSR. Exiting..."
        exit 1
    }

    # Sign the certificate with Root CA
    openssl x509 -req -in "$DOMAIN_CERT_DIR/$FILE_DOMAIN.csr" \
        -CA "$ROOT_CA_DIR/rootCA.crt" -CAkey "$ROOT_CA_DIR/rootCA.key" \
        -CAcreateserial -out "$DOMAIN_CERT_DIR/$FILE_DOMAIN.crt" \
        -days "$DAYS_DOMAIN" -sha256 \
        -extfile "$DOMAIN_CERT_DIR/$FILE_DOMAIN.conf" -extensions req_ext 2>/dev/null || {
        echo "ERROR: Failed to sign domain certificate. Exiting..."
        exit 1
    }

    # Clean up CSR and config file
    rm -f "$DOMAIN_CERT_DIR/$FILE_DOMAIN.csr" "$DOMAIN_CERT_DIR/$FILE_DOMAIN.conf" || {
        echo "WARNING: Failed to clean up temporary files."
    }

    echo "Domain certificate created at $DOMAIN_CERT_DIR/$FILE_DOMAIN.crt"
}

### Main execution
create_root_ca
create_domain_cert

### Verify the certificate
echo "Verifying certificate..."
if ! openssl x509 -in "$DOMAIN_CERT_DIR/$FILE_DOMAIN.crt" -text -noout > /tmp/cert_verify.txt 2>/dev/null; then
    echo "ERROR: Failed to verify certificate. Exiting..."
    exit 1
fi
if grep -A 1 "Subject Alternative Name" /tmp/cert_verify.txt | grep -q "$DOMAIN"; then
    echo "Certificate verification successful: SAN includes $DOMAIN"
else
    echo "ERROR: Certificate verification failed: SAN does not include $DOMAIN"
    exit 1
fi
rm -f /tmp/cert_verify.txt
