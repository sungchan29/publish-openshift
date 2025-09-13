#!/bin/bash

### ---------------------------------------------------------------------------------
### Mirror Additional and Tool Images
### ---------------------------------------------------------------------------------
### This script pulls or builds supplementary images (e.g., for logging, support,
### and upgrade graphs) and saves them as local tar archives.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/oc-mirror-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Validate Environment and Setup
### ---------------------------------------------------------------------------------
### Validate that critical environment variables from the config are set.
printf "%-8s%-80s\n" "[INFO]" "=== Validating prerequisites ==="

### Validate that the required image variables are set in the configuration.
if [[ -z "${EVENTROUTER_IMAGE}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    'EVENTROUTER_IMAGE' variable is not set or empty. Exiting..."
    exit 1
fi
if [[ -z "${SUPPORT_TOOL_IMAGE}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    'SUPPORT_TOOL_IMAGE' variable is not set or empty. Exiting..."
    exit 1
fi
if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Pull secret file '$PULL_SECRET_FILE' not found. Exiting..."
    exit 1
fi

### Function to create a Dockerfile for the graph data image.
printf "%-8s%-80s\n" "[INFO]" "=== Configuration Summary ==="
printf "%-8s%-80s\n" "[INFO]" "    - Output Directory : $OCP_TOOL_IMAGE_DIR"
printf "%-8s%-80s\n" "[INFO]" "    - Pull Secret File : $PULL_SECRET_FILE"

### Set default directory paths if not already defined.
WORK_DIR="${WORK_DIR:-"$(realpath "$PWD")/$OCP_VERSIONS"}"
OCP_TOOL_IMAGE_DIR="${OCP_TOOL_IMAGE_DIR:-"$WORK_DIR/export/additional-images"}"

### Prepare the output directory, cleaning it first if it exists.
if [[ -d "$OCP_TOOL_IMAGE_DIR" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "--- Cleaning up previous image tar files in '$OCP_TOOL_IMAGE_DIR'..."
    rm -f "$OCP_TOOL_IMAGE_DIR"/*.tar
else
    printf "%-8s%-80s\n" "[INFO]" "--- Creating additional images directory: '$OCP_TOOL_IMAGE_DIR'..."
    mkdir -p "$OCP_TOOL_IMAGE_DIR"
fi

### ---------------------------------------------------------------------------------
### Build and Save OpenShift Graph Data Image
### ---------------------------------------------------------------------------------
### Generate the Dockerfile for the graph data image.
create_dockerfile

if [[ -f ./Dockerfile ]]; then
    printf "%-8s%-80s\n" "[INFO]" "--- Building the OpenShift graph data image..."
    ### Build the image using the generated Dockerfile.
    podman build -t localhost/openshift/graph-data:latest -f ./Dockerfile --authfile "$PULL_SECRET_FILE"
    
    printf "%-8s%-80s\n" "[INFO]" "--- Saving graph data image to a tar archive..."
    ### Save the built image to a tar file.
    podman save localhost/openshift/graph-data:latest > "$OCP_TOOL_IMAGE_DIR/localhost_graph-data.tar"

    ### Clean up the temporary Dockerfile.
    rm -f ./Dockerfile
else
    printf "%-8s%-80s\n" "[ERROR]" "    Dockerfile not found. Skipping graph-data image creation."
fi

### ---------------------------------------------------------------------------------
### Pull and Save Event Router and Support Tools Images
### ---------------------------------------------------------------------------------
### Loop through each additional image defined in the configuration.
printf "%-8s%-80s\n" "[INFO]" "=== Pull and Save Event Router and Support Tools Images ==="
for image in ${EVENTROUTER_IMAGE} ${SUPPORT_TOOL_IMAGE}; do
    echo ""
    printf "%-8s%-80s\n" "[INFO]" "    Processing image: $image..."
    
    ### Extract the registry name from the image string (e.g., "registry.redhat.io").
    awk_filter=$(echo "$image" | awk -F "/" '{print $1}')

    ### Pull the image from its source registry.
    printf "%-8s%-80s\n" "[INFO]" "    -- Pulling image..."
    podman pull "$image" --authfile "$PULL_SECRET_FILE"
    
    ### Tag the image with a 'localhost' prefix for local management.
    printf "%-8s%-80s\n" "[INFO]" "    -- Tagging image for local export..."
    podman tag "$image" "localhost/$(echo "$image" | awk -F "${awk_filter}/" '{print $2}')"
    
    ### Save the locally tagged image to a tar file.
    target_name=$(echo "$image" | awk -F "/" '{print $NF}' | awk -F ":" '{print $1}')
    printf "%-8s%-80s\n" "[INFO]" "    -- Saving image to '$OCP_TOOL_IMAGE_DIR/localhost_$target_name.tar'..."
    podman save "localhost/$(echo "$image" | awk -F "${awk_filter}/" '{print $2}')" > "$OCP_TOOL_IMAGE_DIR/localhost_$target_name.tar"
    
    ### Remove the locally tagged image to clean up.
    printf "%-8s%-80s\n" "[INFO]" "    -- Cleaning up local tag..."
    podman rmi "localhost/$(echo "$image" | awk -F "${awk_filter}/" '{print $2}')"
    
    ### (Optional) Load the image from the tar to verify its integrity.
    printf "%-8s%-80s\n" "[INFO]" "    -- Verifying tar archive by loading it..."
    podman load -i "$OCP_TOOL_IMAGE_DIR/localhost_$target_name.tar" > /dev/null
done

### ---------------------------------------------------------------------------------
### Completion Summary
### ---------------------------------------------------------------------------------
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== All additional images have been processed successfully. ==="
printf "%-8s%-80s\n" "[INFO]" "    Saved image tar files in directory: $OCP_TOOL_IMAGE_DIR"
ls -lrt "$OCP_TOOL_IMAGE_DIR"
echo ""