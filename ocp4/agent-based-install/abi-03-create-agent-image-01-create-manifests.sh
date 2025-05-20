#!/bin/bash

### Enable strict mode
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

### Validate dependencies
if echo "$PATH" | grep -q "^$PWD"; then
    echo "[INFO] Current directory is already in PATH."
else
    export PATH="$PWD:$PATH"
    echo "[INFO] Added current directory to PATH for 'oc' and 'openshift-install'."
fi

if [[ ! -x "./openshift-install" ]]; then
    echo "[ERROR] './openshift-install' is not executable or does not exist. Exiting..."
    echo "[INFO] To resolve this issue, run: sh abi-02-install-openshift-tools.sh"
    exit 1
fi

### Validate OCP_VERSION matches openshift-install version
echo "[INFO] Validating OCP_VERSION against openshift-install version..."
install_version=$(./openshift-install version | head -n 1 | awk '{print $2}' || echo "")
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
if [[ -f "$MIRROR_REGISTRY_TRUST_FILE" ]]; then
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"
    echo "[INFO] $(env | grep OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE)"

    ### Validate required variables
    for var in "MIRROR_REGISTRY" "LOCAL_REPOSITORY_NAME" "PULL_SECRET"; do
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
    ### Validate PULL_SECRET
    if command -v jq --version >/dev/null 2>&1; then
        if [[ ! -f "$PULL_SECRET" ]] || ! jq . "$PULL_SECRET" >/dev/null 2>&1; then
            echo "[ERROR] PULL_SECRET file '$PULL_SECRET' does not exist or is not valid JSON. Exiting..."
            exit 1
        fi
    fi
    
    ### Test registry connectivity
    echo "[INFO] Testing connectivity to mirror registry '$MIRROR_REGISTRY'..."
    if ! curl -s -k -m 10 "https://$MIRROR_REGISTRY/v2/" >/dev/null; then
        echo "[WARN] Failed to connect to mirror registry '$MIRROR_REGISTRY'. Proceeding without connectivity check..."
    else
        echo "[INFO] Successfully connected to mirror registry '$MIRROR_REGISTRY'."
    fi

    ### Validate release image with podman
    if command -v podman >/dev/null 2>&1; then
        echo "[INFO] Validating release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'..."
        set +e
        output=$(podman pull --authfile "$PULL_SECRET" --tls-verify=false "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        pull_exit_code=$?
        set -e
        if [[ $pull_exit_code -ne 0 ]]; then
            echo "[ERROR] Failed to pull release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'. Exiting..."
            echo "[ERROR] Details: $output"
            exit 1
        fi
        echo "[INFO] Successfully pulled release image."

        echo "[INFO] Inspecting release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'..."
        set +e
        output=$(podman inspect "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" 2>&1)
        inspect_exit_code=$?
        set -e
        if [[ $inspect_exit_code -ne 0 ]]; then
            echo "[ERROR] Failed to inspect release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'. Exiting..."
            echo "[ERROR] Details: $output"
            exit 1
        fi
        echo "[INFO] Successfully inspected release image."
        podman rmi "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" || {
            echo "[WARN] Failed to remove release image '$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE' from local storage."
        }
        echo "[INFO] Removed release image from local storage."
    else
        echo "[WARN] 'podman' not found, skipping release image validation."
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
for file in "${source_files[@]}"; do
    cp -f "$file" "./$CLUSTER_NAME/" || {
        echo "[ERROR] Failed to copy '$file' to './$CLUSTER_NAME'. Exiting..."
        exit 1
    }
    echo "[INFO] Copied '$file' to './$CLUSTER_NAME'"
done

if [[ -d "$ADDITIONAL_MANIFEST" ]]; then
    cp -Rf "$ADDITIONAL_MANIFEST/" "./$CLUSTER_NAME/" || {
        echo "[ERROR] Failed to copy '$ADDITIONAL_MANIFEST' to './$CLUSTER_NAME'. Exiting..."
        exit 1
    }
    echo "[INFO] Copied '$ADDITIONAL_MANIFEST' to './$CLUSTER_NAME'"
else
    echo "[ERROR] Directory '$ADDITIONAL_MANIFEST' does not exist. Please check the path and try again. Exiting..."
    exit 1
fi

### Generate cluster manifests
echo "[INFO] Generating cluster manifests in './$CLUSTER_NAME'..."
if ! ./openshift-install agent create cluster-manifests --dir "./$CLUSTER_NAME" --log-level info 2>&1; then
    echo "[ERROR] Failed to generate cluster manifests. Check logs for details. Exiting..."
    exit 1
fi

### List directory structure (optional, for debugging)
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of './$CLUSTER_NAME':"
    tree "./$CLUSTER_NAME"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "./$CLUSTER_NAME"
fi

echo "[INFO] Successfully completed manifest generation."