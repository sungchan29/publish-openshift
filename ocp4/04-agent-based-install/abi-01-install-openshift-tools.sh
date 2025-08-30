#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Validate required variables
validate_non_empty "LOCAL_REPOSITORY_NAME" "$LOCAL_REPOSITORY_NAME"
validate_file "$PULL_SECRET"
validate_file "$OPENSHIFT_CLIENT_TAR_FILE"
validate_file "$BUTANE_FILE"

### Clean up existing binaries
echo "[INFO] Starting cleanup of existing binaries..."
for binary in oc openshift-install butane; do
    if [[ -f "./$binary" ]]; then
        if lsof "./$binary" >/dev/null 2>&1; then
            echo "[WARN] $binary is in use. Skipping deletion."
        else
            echo "[INFO] Removing existing binary '$binary'..."
            rm -f "./$binary"
            echo "[INFO] Successfully removed '$binary'."
        fi
    fi
done
echo "[INFO] Completed cleanup of existing binaries."

### Extract oc from tar file
echo "[INFO] Extracting oc from '$OPENSHIFT_CLIENT_TAR_FILE'..."
tar xvf "$OPENSHIFT_CLIENT_TAR_FILE" -C "./" oc

echo "[INFO] Successfully extracted oc binary."
echo "[INFO] Setting permissions for oc..."
chmod ug+x ./oc

### Create idms-oc-mirror.yaml
echo "[INFO] Starting creation of idms-oc-mirror.yaml..."
cat << EOF > ./idms-oc-mirror.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release-images
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors:
    - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOF
if [[ ! -f "./idms-oc-mirror.yaml" ]]; then
    echo "[ERROR] Failed to create idms-oc-mirror.yaml. Exiting..."
    exit 1
fi
echo "[INFO] Successfully created idms-oc-mirror.yaml."

### Extract openshift-install from release image
echo "[INFO] Starting openshift-install extraction..."
if [[ -f ./oc ]] && [[ -f ./idms-oc-mirror.yaml ]]; then
    echo "[INFO] Extracting openshift-install from release image '$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64'..."
    ./oc adm release extract -a "$PULL_SECRET" --insecure=true --idms-file='./idms-oc-mirror.yaml' --command=openshift-install "$MIRROR_REGISTRY/$LOCAL_REPOSITORY_NAME/release-images:${OCP_VERSION}-x86_64"

    if [[ ! -f ./openshift-install ]]; then
        echo "[ERROR] openshift-install binary not found after extraction. Exiting..."
        exit 1
    fi
    echo "[INFO] Successfully extracted openshift-install binary."
    echo "[INFO] Setting permissions for openshift-install..."
    chmod ug+x ./openshift-install
    if ! ./openshift-install version >/dev/null 2>&1; then
        echo "[ERROR] Extracted openshift-install is not executable. Exiting..."
        exit 1
    fi
    echo "[INFO] openshift-install binary is executable."
else
    echo "[ERROR] OpenShift client binary or idms-oc-mirror.yaml not found. Exiting..."
    exit 1
fi

### Copy butane binary
echo "[INFO] Starting butane binary copy..."
echo "[INFO] Copying butane from '$BUTANE_FILE'..."
cp "$BUTANE_FILE" ./butane || {
    echo "[ERROR] Failed to copy butane. Exiting..."
    exit 1
}
echo "[INFO] Successfully copied butane binary."
echo "[INFO] Setting permissions for butane..."
chmod ug+x ./butane
if ! ./butane --version >/dev/null 2>&1; then
    echo "[ERROR] Copied butane is not executable. Exiting..."
    exit 1
fi
echo "[INFO] butane binary is executable."

### Final completion message
echo "[INFO] All setup steps completed successfully."