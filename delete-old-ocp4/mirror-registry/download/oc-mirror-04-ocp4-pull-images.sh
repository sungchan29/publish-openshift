#!/bin/bash

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access 'config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
source "$config_file"


### Check if pull_secret file exists and apply its contents
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    ### If pull secret file does not exist, log error and exit
    echo "[ERROR] Cannot access 'PULL_SECRET_FILE'. File does not exist. Exiting..."
    exit 1
fi

### Validate EVENTROUTER_IMAGE environment variable
if [[ -z "${EVENTROUTER_IMAGE}" ]]; then
    echo "[ERROR] 'EVENTROUTER_IMAGE' is not set or empty. Exiting..."
    exit 1
fi

### Validate SUPPORT_TOOL_IMAGE environment variable
if [[ -z "${SUPPORT_TOOL_IMAGE}" ]]; then
    echo "[ERROR] 'SUPPORT_TOOL_IMAGE' is not set or empty. Exiting..."
    exit 1
fi

WORK_DIR="${WORK_DIR:-"$(realpath "$PWD")/$OCP_VERSIONS"}"
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

echo "--------------------"
echo "OCP_TOOL_IMAGE_DIR : $OCP_TOOL_IMAGE_DIR"
echo "PULL_SECRET_FILE   : $PULL_SECRET_FILE"
echo "--------------------"

if [[ -d "$OCP_TOOL_IMAGE_DIR" ]]; then
    rm -f "$OCP_TOOL_IMAGE_DIR"/*.tar
    echo "[INFO] Cleaned up previous image tar files in '$OCP_TOOL_IMAGE_DIR'."
else
    mkdir -p $OCP_TOOL_IMAGE_DIR
fi

### Create OpenShift Graph Data Image
create_dockerfile

if [[ -f ./Dockerfile ]]; then
    ### Build the graph-data image
    podman build -t localhost/openshift/graph-data:latest -f ./Dockerfile --authfile $PULL_SECRET_FILE
    podman save localhost/openshift/graph-data:latest > "$OCP_TOOL_IMAGE_DIR/localhost_graph-data.tar"

    rm -f ./Dockerfile

    echo "[INFO] Graph data image built and saved to '$OCP_TOOL_IMAGE_DIR/localhost_graph-data.tar'."
else
    echo "[ERROR] Dockerfile not found. Skipping graph-data image creation."
fi

### Process Event Router and Support Tools Images
for image in ${EVENTROUTER_IMAGE} ${SUPPORT_TOOL_IMAGE}; do
    ### Extract registry name for image manipulation
    awk_filter=$(echo "$image" | awk -F "/" '{print $1}')

    echo ""
    ### Pull, tag, save, remove local tag, and load the image
    podman pull $image --authfile $PULL_SECRET_FILE
    podman tag  $image localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}')
    target_name=$(echo $image | awk -F "/" '{print $NF}' | awk -F ":" '{print $1}')
    podman save localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}') > $OCP_TOOL_IMAGE_DIR/localhost_$target_name.tar
    podman rmi  localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}')
    podman load -i $OCP_TOOL_IMAGE_DIR/localhost_$target_name.tar
done

### Indicate that the setup process has completed successfully
echo "[INFO] Setup completed successfully."
echo ""
echo "Listing files in $OCP_TOOL_IMAGE_DIR :"
ls -lrt $OCP_TOOL_IMAGE_DIR
