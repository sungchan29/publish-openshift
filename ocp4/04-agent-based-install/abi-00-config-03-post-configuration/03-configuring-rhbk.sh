#!/bin/bash

### ---------------------------------------------------------------------------------
### Configure Red Hat build of Keycloak (RHBK)
### ---------------------------------------------------------------------------------
### Reference:
### - Installing RHBK using the CLI
### - Basic Red Hat build of Keycloak deployment
###
### This script installs the RHBK Operator and deploys a basic Keycloak instance.
### It includes a demo Postgres database required for the Keycloak instance.

### Enable strict mode.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Path & Config Loading
### ---------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
config_file="${ROOT_DIR}/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Config not found: $config_file"
    exit 1
fi
source "$config_file"

### OC Command Check
if [[ -f "${ROOT_DIR}/oc" ]]; then
    OC_CMD="${ROOT_DIR}/oc"
elif command -v oc &> /dev/null; then
    OC_CMD="oc"
else
    printf "%-12s%-80s\n" "[ERROR]" "'oc' binary not found. Exiting..."
    exit 1
fi

### ---------------------------------------------------------------------------------
### Variables
### ---------------------------------------------------------------------------------
OPERATOR_NAMESPACE="rhbk-operator"
INSTANCE_NAMESPACE="rhbk-site"
OPERATOR_PACKAGE="rhbk-operator"
TARGET_CHANNEL="stable-v26"

### Keycloak Instance Config
HOSTNAME_URL="keycloak.${CLUSTER_NAME}.${BASE_DOMAIN}"
DB_SECRET_NAME="keycloak-db-secret"
TLS_SECRET_NAME="example-tls-secret"

### Database Image Config (Important for Disconnected Env)
### You can override this by exporting POSTGRES_IMAGE before running the script.
### e.g., export POSTGRES_IMAGE="registry.cloudpang.lan:5000/postgres:15"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15}"


### ---------------------------------------------------------------------------------
### Part 1: Install RHBK Operator (CLI)
### ---------------------------------------------------------------------------------
printf "%-12s%-80s\n" "[INFO]" "=== Part 1: Installing RHBK Operator ==="

### 1. Create Namespace
printf "%-12s%-80s\n" "[INFO]" "-- Creating Namespace '$OPERATOR_NAMESPACE'..."
CMD_STR="$OC_CMD create namespace $OPERATOR_NAMESPACE --dry-run=client -o yaml | $OC_CMD apply -f -"
printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
printf "%-12s%-80s\n" "[INFO]" "        $CMD_STR"
eval "$CMD_STR" > /dev/null

### 2. Create OperatorGroup
printf "%-12s%-80s\n" "[INFO]" "-- Creating OperatorGroup in '$OPERATOR_NAMESPACE'..."
OG_YAML="apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk-operator-group
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE"

CMD_STR="echo \"\$OG_YAML\" | $OC_CMD apply -f -"
printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
printf "%-12s%-80s\n" "[INFO]" "        echo \"(OperatorGroup YAML)\" | $OC_CMD apply -f -"
echo "$OG_YAML" | $OC_CMD apply -f - > /dev/null

### 3. Create Subscription
printf "%-12s%-80s\n" "[INFO]" "-- Creating Subscription..."

ocp_major_minor="$(echo "$OCP_VERSION" | grep -oE '^[0-9]+\.[0-9]+' || true)"

# Find CatalogSource
catalog_source=$($OC_CMD -n openshift-marketplace get catalogsources -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "redhat-operator-index:v${ocp_major_minor}" | awk '{print $1}')
if [[ -z "$catalog_source" ]]; then
    catalog_source=$($OC_CMD -n openshift-marketplace get catalogsources -o name | grep "redhat-operator" | head -n 1 | cut -d/ -f2)
fi
if [[ -z "$catalog_source" ]]; then
    printf "%-12s%-80s\n" "[ERROR]" "Could not find a suitable Red Hat Operator catalog source."
    exit 1
fi
printf "%-12s%-80s\n" "[INFO]" "    > Using CatalogSource: $catalog_source"

# Clean up failed CSVs (Self-Healing)
CURRENT_CSV=$($OC_CMD -n "$OPERATOR_NAMESPACE" get subscription "$OPERATOR_PACKAGE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
if [[ -n "$CURRENT_CSV" ]]; then
    CSV_PHASE=$($OC_CMD -n "$OPERATOR_NAMESPACE" get csv "$CURRENT_CSV" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$CSV_PHASE" == "Failed" ]]; then
        printf "%-12s%-80s\n" "[WARN]" "Found failed CSV '$CURRENT_CSV'. Deleting to force re-install..."
        $OC_CMD -n "$OPERATOR_NAMESPACE" delete csv "$CURRENT_CSV" > /dev/null
    fi
fi

# Apply Subscription YAML
SUB_YAML="apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $OPERATOR_PACKAGE
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $TARGET_CHANNEL
  installPlanApproval: Automatic
  source: $catalog_source
  sourceNamespace: openshift-marketplace
  name: $OPERATOR_PACKAGE"

CMD_STR="echo \"\$SUB_YAML\" | $OC_CMD apply -f -"
printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
printf "%-12s%-80s\n" "[INFO]" "        echo \"(Subscription YAML)\" | $OC_CMD apply -f -"
echo "$SUB_YAML" | $OC_CMD apply -f - > /dev/null

### 4. Wait for Operator Installation
printf "%-12s%-80s\n" "[INFO]" "Waiting for Operator installation..."
CSV_NAME=""
for ((i=1; i<=60; i++)); do
    CSV_NAME=$($OC_CMD -n "$OPERATOR_NAMESPACE" get subscription "$OPERATOR_PACKAGE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$CSV_NAME" ]]; then
        printf "\n%-12s%-80s\n" "[INFO]" "    > Found CSV: $CSV_NAME"
        break
    fi
    printf "\r%-12s%-80s" "[INFO]" "    > Waiting for CSV creation... ($i/60)"
    sleep 5
done

if [[ -z "$CSV_NAME" ]]; then
    printf "\n%-12s%-80s\n" "[ERROR]" "Timed out waiting for CSV creation."
    exit 1
fi

# Wait for CSV Succeeded
printf "%-12s%-80s\n" "[INFO]" "-- Waiting for CSV '$CSV_NAME' to succeed..."
$OC_CMD -n "$OPERATOR_NAMESPACE" wait csv "$CSV_NAME" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s > /dev/null

# Wait for Pod Ready
printf "%-12s%-80s\n" "[INFO]" "-- Waiting for Operator Pod to be Ready..."
$OC_CMD -n "$OPERATOR_NAMESPACE" wait pod -l name=rhbk-operator --for=condition=Ready --timeout=300s > /dev/null

printf "%-12s%-80s\n" "[INFO]" "=== RHBK Operator Installed Successfully ==="


### ---------------------------------------------------------------------------------
### Part 2: Basic Keycloak Deployment
### ---------------------------------------------------------------------------------
printf "\n%-12s%-80s\n" "[INFO]" "=== Part 2: Deploying Basic Keycloak Instance ==="

### 1. Create Instance Namespace
printf "%-12s%-80s\n" "[INFO]" "-- Creating Namespace '$INSTANCE_NAMESPACE'..."
$OC_CMD create namespace "$INSTANCE_NAMESPACE" --dry-run=client -o yaml | $OC_CMD apply -f - > /dev/null

### 2. Deploy Ephemeral Database (Prerequisite)
# RHBK requires an external DB.
printf "%-12s%-80s\n" "[INFO]" "-- Deploying Ephemeral Postgres DB..."
printf "%-12s%-80s\n" "[INFO]" "    > Using Image: $POSTGRES_IMAGE"

# Postgres Service
$OC_CMD -n "$INSTANCE_NAMESPACE" apply -f - <<EOF > /dev/null
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  labels:
    app: postgres
spec:
  ports:
  - port: 5432
  selector:
    app: postgres
EOF

# Postgres Deployment
$OC_CMD -n "$INSTANCE_NAMESPACE" apply -f - <<EOF > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-db
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: $POSTGRES_IMAGE
        env:
        - name: POSTGRES_DB
          value: keycloak
        - name: POSTGRES_USER
          value: keycloak
        - name: POSTGRES_PASSWORD
          value: password
        ports:
        - containerPort: 5432
EOF

printf "%-12s%-80s\n" "[INFO]" "    > Waiting for Postgres DB to be Ready..."
if ! $OC_CMD -n "$INSTANCE_NAMESPACE" wait pod -l app=postgres --for=condition=Ready --timeout=300s > /dev/null; then
    printf "\n%-12s%-80s\n" "[ERROR]" "Timeout waiting for Postgres DB to become ready."
    printf "%-12s%-80s\n" "[ERROR]" "This is likely due to an ImagePullBackOff (missing image in disconnected env)."
    printf "%-12s%-80s\n" "[INFO]" "--- Debug: Pod Status ---"
    $OC_CMD -n "$INSTANCE_NAMESPACE" get pods -l app=postgres
    printf "%-12s%-80s\n" "[INFO]" "--- Debug: Events ---"
    $OC_CMD -n "$INSTANCE_NAMESPACE" describe pods -l app=postgres | grep -A 10 Events
    exit 1
fi

### 3. Create Secrets
printf "%-12s%-80s\n" "[INFO]" "-- Creating Database Secret..."
$OC_CMD -n "$INSTANCE_NAMESPACE" create secret generic "$DB_SECRET_NAME" \
  --from-literal=username=keycloak \
  --from-literal=password=password \
  --dry-run=client -o yaml | $OC_CMD apply -f - > /dev/null

printf "%-12s%-80s\n" "[INFO]" "-- Creating TLS Secret (Self-signed)..."
openssl req -x509 -newkey rsa:4096 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=$HOSTNAME_URL" 2>/dev/null
$OC_CMD -n "$INSTANCE_NAMESPACE" create secret tls "$TLS_SECRET_NAME" \
  --cert=/tmp/tls.crt \
  --key=/tmp/tls.key \
  --dry-run=client -o yaml | $OC_CMD apply -f - > /dev/null
rm -f /tmp/tls.key /tmp/tls.crt

### 4. Deploy Keycloak Custom Resource
printf "%-12s%-80s\n" "[INFO]" "-- Deploying Keycloak CR..."
KC_YAML="apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: example-keycloak
  namespace: $INSTANCE_NAMESPACE
  labels:
    app: sso
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-db
    usernameSecret:
      name: $DB_SECRET_NAME
      key: username
    passwordSecret:
      name: $DB_SECRET_NAME
      key: password
  http:
    enabled: true
  hostname:
    hostname: $HOSTNAME_URL
  tls:
    enabled: true
    certificateSecret:
      name: $TLS_SECRET_NAME"

CMD_STR="echo \"\$KC_YAML\" | $OC_CMD apply -f -"
printf "%-12s%-80s\n" "[INFO]" "    > Executing:"
printf "%-12s%-80s\n" "[INFO]" "        echo \"(Keycloak CR YAML)\" | $OC_CMD apply -f -"
echo "$KC_YAML" | $OC_CMD apply -f - > /dev/null

### 5. Wait for Keycloak Ready
printf "%-12s%-80s\n" "[INFO]" "Waiting for Keycloak instance to be Ready..."
printf "%-12s%-80s\n" "[INFO]" "(This may take a few minutes while it builds and starts)"

for ((i=1; i<=200; i++)); do
    KC_READY=$($OC_CMD -n "$INSTANCE_NAMESPACE" get keycloak example-keycloak -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    if [[ "$KC_READY" == "true" ]]; then
        printf "\n%-12s%-80s\n" "[INFO]" "    > Keycloak is Ready!"
        break
    fi
    printf "\r%-12s%-80s" "[INFO]" "    > Waiting for Keycloak... ($i/200)"
    sleep 3
done

if [[ "$KC_READY" != "true" ]]; then
    printf "\n%-12s%-80s\n" "[WARN]" "Keycloak did not become ready within the timeout."
    printf "%-12s%-80s\n" "[WARN]" "Check status with: oc get keycloak -n $INSTANCE_NAMESPACE"
    exit 1
fi

printf "\n%-12s%-80s\n" "[INFO]" "SUCCESS: Red Hat build of Keycloak deployed."
printf "%-12s%-80s\n" "[INFO]" "    URL: https://$HOSTNAME_URL"