#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Configuration file '$config_file' does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Validate required variables
validate_file "$PULL_SECRET"

### Validate pull-secret
if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$PULL_SECRET" >/dev/null 2>&1; then
        echo "[ERROR] PULL_SECRET '$PULL_SECRET' is not a valid JSON file. Exiting..."
        exit 1
    fi
    echo "[INFO] PULL_SECRET validated successfully."
else
    echo "[WARN] 'jq' not found, skipping PULL_SECRET JSON validation."
fi

### Validate dependencies
if [[ ! -x "./oc" ]]; then
    echo "[ERROR] './oc' is not executable or does not exist. Exiting..."
    echo "[INFO] Ensure OpenShift CLI is installed and executable (chmod +x oc)."
    exit 1
fi

if echo "$PATH" | grep -q -F -- "$PWD"; then
    echo "[INFO] Current directory is already in PATH."
else
    export PATH="$PATH:$PWD"
    echo "[INFO] Added current directory to PATH for 'oc'"
fi

if [[ ! -x "./openshift-install" ]]; then
    echo "[ERROR] './openshift-install' is not executable or does not exist. Exiting..."
    echo "[INFO] To resolve this issue, run: sh abi-02-install-openshift-tools.sh"
    exit 1
fi

### Validate OCP_VERSION matches openshift-install version
echo "[INFO] Validating OCP_VERSION against openshift-install version..."
install_version=$(./openshift-install version | head -n 1 | awk '{print $2}')
if [[ -z "$install_version" ]]; then
    echo "[ERROR] Failed to extract version from './openshift-install version'. Exiting..."
    exit 1
fi
if [[ "$OCP_VERSION" != "$install_version" ]]; then
    echo "[ERROR] OCP_VERSION '$OCP_VERSION' does not match openshift-install version '$install_version'. Exiting..."
    exit 1
fi
echo "[INFO] OCP_VERSION '$OCP_VERSION' matches openshift-install version '$install_version'."

### Validate mirror registry settings
if [[ -n "${MIRROR_REGISTRY_TRUST_FILE:-}" && -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
    for var in "MIRROR_REGISTRY" "LOCAL_REPOSITORY_NAME"; do
        if [[ -z "${!var}" ]]; then
            echo "[ERROR] Required variable '$var' is empty when MIRROR_REGISTRY_TRUST_FILE is set. Exiting..."
            exit 1
        fi
    done
    ### Validate certificate file
    if [[ ! -s "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
        echo "[ERROR] MIRROR_REGISTRY_TRUST_FILE '$MIRROR_REGISTRY_TRUST_FILE' is empty. Exiting..."
        exit 1
    fi
    if ! grep -q "^-----BEGIN CERTIFICATE-----" "$MIRROR_REGISTRY_TRUST_FILE"; then
        echo "[ERROR] MIRROR_REGISTRY_TRUST_FILE '$MIRROR_REGISTRY_TRUST_FILE' does not contain a valid certificate. Exiting..."
        exit 1
    fi
    ### Set release image override
    if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
        export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
        echo "[INFO] Set OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'"

        ### Validate release image
        if command -v podman >/dev/null 2>&1; then
            if ! podman pull "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" --authfile "$PULL_SECRET" --tls-verify=false >/dev/null 2>&1; then
                echo "[ERROR] Failed to pull release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'. Check registry or credentials. Exiting..."
                exit 1
            fi
            ### Inspect image metadata with debug output
            if ! podman inspect "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" --authfile "$PULL_SECRET" --tls-verify=false; then
                echo "[WARN] Failed to inspect release image metadata."
            else
                echo "[INFO] Successfully inspected release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'"
            fi
            echo "[INFO] Successfully validated release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'"
        else
            echo "[WARN] 'podman' not found, skipping release image validation."
        fi
    fi
fi

### Validate source files and copy
declare -a source_files=(
    "./$CLUSTER_NAME/orig/agent-config.yaml"
    "./$CLUSTER_NAME/orig/install-config.yaml"
)
for file in "${source_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "[ERROR] Required file '$file' does not exist. Exiting..."
        echo "[INFO] Run 'abi-02-create-file-01-agent-config.sh' or 'abi-03-create-file-02-install-config.sh' to generate missing files."
        exit 1
    fi
done

# Copy files
mkdir -p "./$CLUSTER_NAME"
for file in "${source_files[@]}"; do
    cp -f "$file" "./$CLUSTER_NAME/"
    echo "[INFO] Copied '$file' to './$CLUSTER_NAME'"
done

# Copy openshift directory if it exists
if [[ -d "$ADDITIONAL_MANIFEST" ]]; then
    cp -Rf "$ADDITIONAL_MANIFEST" "./$CLUSTER_NAME/"
    echo "[INFO] Copied openshift directory to './$CLUSTER_NAME'"
fi

### Generate cluster manifests
echo "[INFO] Generating cluster manifests in './$CLUSTER_NAME'..."
echo "DEBUG: Environment variables:"
if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
fi
echo "PATH=$PATH"

./openshift-install agent create cluster-manifests --dir "./$CLUSTER_NAME" --log-level info

echo "[INFO] Cluster manifests generated successfully."

### Clean up temporary files
if [[ -d "./tmp" ]]; then
    echo "[INFO] Cleaning up temporary files in './tmp'..."
    rm -rf ./tmp/*
fi

### List directory structure (optional, for debugging)
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of './$CLUSTER_NAME':"
    tree "./$CLUSTER_NAME"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "./$CLUSTER_NAME"
fi