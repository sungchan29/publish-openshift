#!/bin/bash

### Define the OpenShift versions to mirror, separated by '--'
### These are the OCP versions that will be processed (e.g., 4.17.9, 4.17.15, 4.18.4)
OCP_VERSIONS="4.19.9"

### Define OLM (Operator Lifecycle Manager) catalogs to use, separated by '--'
### Examples include 'redhat', 'certified', 'community'; empty by default to set later
OLM_CATALOGS="redhat"
OLM_CATALOGS="redhat--certified"

### MIRROR_REGISTRY is the target registry URL where images will be pushed
MIRROR_REGISTRY="registry.hub.tistory.disconnected:5000"
### MIRROR_REGISTRY_USERNAME is the username for logging into the registry
MIRROR_REGISTRY_USERNAME="admin"

### Command path for oc-mirror tool
### Path to the oc-mirror binary; defaults to current directory if not set($PWD/oc-mirror)
OC_MIRROR_CMD=""

### Directory paths for OCP tools and images
INSTALL_FILES_BASE_DIR="/root/ocp4/download/$OCP_VERSIONS"
OCP_OLM_IMAGES_DIR="$INSTALL_FILES_BASE_DIR/export/oc-mirror"
OCP_ADD_IMAGES_DIR="$INSTALL_FILES_BASE_DIR/export/additional-images"
OC_MIRROR_TOOL_DIR="$INSTALL_FILES_BASE_DIR/export/tool-binaries"

OC_MIRROR_RHEL8_TAR="$OC_MIRROR_TOOL_DIR/oc-mirror.tar.gz"
OC_MIRROR_RHEL9_TAR="$OC_MIRROR_TOOL_DIR/oc-mirror.rhel9.tar.gz"

### Repository paths for OCP and OLM images
### These define namespaces in the mirror registry; defaults set later if not specified
OCP_REPOSITORY=""
OLM_REDHAT_REPOSITORY=""
OLM_CERTIFIED_REPOSITORY=""
OLM_COMMUNITY_REPOSITORY=""

### Cache directory for oc-mirror
### Directory to store oc-mirror cache; defaults to user's home directory if not set
OC_MIRROR_CACHE_DIR=""


###
### Setup and Utility Functions
### Initialize configuration variables and define functions for OpenShift mirroring
###

### Check if oc-mirror tool exists
### Set default path for oc-mirror if not already defined
### If OC_MIRROR_CMD is empty, defaults to '$PWD/oc-mirror' in the current directory
OC_MIRROR_CMD="${OC_MIRROR_CMD:-"$PWD/oc-mirror"}"


###
### Function to check if oc-mirror tool is available
###

### Extract the oc-mirror binary based on the RHEL version
### Depending on the RHEL version, extract the appropriate tarball for oc-mirror
extract_oc_mirror() {
    local file=$1
    local tool=$2
    if [[ -f "$file" ]]; then
        echo "[INFO] Extracting oc-mirror from $file..."
        tar xvf "$file" -C ./ $tool
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to extract $file. Exiting..."
            exit 1
        fi
    else
        echo "ERROR: $file not found. Exiting..."
        exit 1
    fi
}

check_oc_mirror() {
    ### Check if the oc-mirror binary exists at the specified path
    if [[ ! -f "$OC_MIRROR_CMD" ]]; then
        ### If oc-mirror is not found, print error and instructions, then exit
        echo "[ERROR]: 'oc-mirror' tool not found at $OC_MIRROR_CMD."
        echo "[INFO]: Please extract oc-mirror from $OPENSHIT_TOOLS_DIR and place it in $PWD/."
        echo "[INFO]: Example commands:"
        echo "        tar -xzf $OPENSHIT_TOOLS_DIR/oc-mirror.tar.gz -C $PWD/"
        echo "        chmod +x $OC_MIRROR_CMD"
        exit 1
    else
        ### If oc-mirror is found, print confirmation message
        echo "[INFO]: 'oc-mirror' tool found at $OC_MIRROR_CMD."
    fi
}

login_to_registry() {
    ### Check Mirror Registry Login
    ### Ensure the user is logged into the mirror registry
    if [[ "$MIRROR_REGISTRY_USERNAME" != "$(podman login --tls-verify=false --get-login "$MIRROR_REGISTRY" 2>/dev/null)" ]]; then
        ### If not logged in, attempt to log in
        echo "[INFO]: Logging into Mirror Registry: $MIRROR_REGISTRY"
        ### Check if running in interactive mode (terminal available)
        if [[ -t 0 ]]; then
            ### Interactive mode: Prompt for password
            podman login --tls-verify=false -u "$MIRROR_REGISTRY_USERNAME" "$MIRROR_REGISTRY"
        else
            ### Non-interactive mode: Exit with error as password cannot be prompted
            echo "[ERROR]: Non-interactive mode detected. Please provide registry password or log in manually."
            exit 1
        fi
    else
        ### If already logged in, print confirmation
        echo "[INFO]: Already logged into Mirror Registry: $MIRROR_REGISTRY"
    fi
}

### Mirror Images Function
### Function to mirror images using oc-mirror with provided config, work directory, and repository
mirror_images() {
    ### Local variables for function arguments
    local _imageset_config_file="$1"  # Path to the ImageSet configuration file
    local _oc_mirror_work_dir="$2"    # Working directory for oc-mirror
    local _repository="$3"            # Repository namespace in the mirror registry
    ### Set cache directory; defaults to user's home directory if not specified
    local _oc_mirror_cache_dir="${OC_MIRROR_CACHE_DIR:-"$HOME"}"

    ### Ensure oc-mirror tool is available
    check_oc_mirror

    ### Print debug information about the mirroring process
    echo ""
    echo "[DEBUG]: ImageSet Config File: $_imageset_config_file"
    echo "[DEBUG]: Work Directory: $_oc_mirror_work_dir"
    echo "[DEBUG]: Repository: $_repository"
    echo ""

    ### Validate that the imageset config file exists
    if [[ ! -f "$_imageset_config_file" ]]; then
        echo "[ERROR]: ImageSet config file not found: $_imageset_config_file"
        exit 1
    fi

    ### Validate that the working directory exists
    if [[ ! -d "$_oc_mirror_work_dir/working-dir" ]]; then
        echo "[ERROR]: Working directory not found: $_oc_mirror_work_dir/working-dir"
        exit 1
    fi

    login_to_registry

    ### Execute oc-mirror command to mirror images to the specified registry
    ### Options:
    ### --v2: Use v2 protocol for mirroring
    ### --cache-dir: Specify cache directory
    ### --config: Path to ImageSet config file
    ### --from: Source directory for local mirroring
    ### docker://: Target registry URL
    "$OC_MIRROR_CMD" --v2 \
        --dest-tls-verify=false \
        --cache-dir "$_oc_mirror_cache_dir" \
        --config    "$_imageset_config_file" \
        --from      "file://$_oc_mirror_work_dir" \
        "docker://$MIRROR_REGISTRY/$_repository"
}

### Get image type from script argument
image_type="$1"
### Check if image_type argument is provided
if [[ $# -ne 1 ]]; then
    ### If no argument is provided, print usage and exit
    echo "[ERROR]: Please provide an image type as an argument."
    echo "[USAGE]: $0 <image_type> (e.g., tool, ocp, olm, add)"
    exit 1
fi


### Set default values for variables if not already defined
### OLM_CATALOGS defaults to 'redhat' if empty
OLM_CATALOGS="${OLM_CATALOGS:-"redhat"}"
### OCP_REPOSITORY defaults to 'ocp4' if empty
OCP_REPOSITORY="${OCP_REPOSITORY:-"ocp4"}"
### OLM repository defaults for each catalog type
OLM_REDHAT_REPOSITORY="${OLM_REDHAT_REPOSITORY:-"olm-redhat"}"
OLM_CERTIFIED_REPOSITORY="${OLM_CERTIFIED_REPOSITORY:-"olm-certified"}"
OLM_COMMUNITY_REPOSITORY="${OLM_COMMUNITY_REPOSITORY:-"olm-community"}"

### Parse OCP versions and catalogs into arrays for processing
### Replace '--' with '|' for easier splitting
parsed_ocp_versions="$(echo "$OCP_VERSIONS" | sed 's/--/|/g')"
### Split OCP versions into an array using '|' as delimiter
IFS='|' read -r -a version_range <<< "$parsed_ocp_versions"
### Split OLM catalogs into an array using '|' as delimiter
IFS='|' read -r -a catalogs      <<< "$(echo "$OLM_CATALOGS" | sed 's/--/|/g')"
### Reset IFS to default to avoid affecting later operations
unset IFS


### Process based on image_type argument
case "$image_type" in
    "tool")
        ### Determine the RHEL version of the system
        ### Extract the RHEL version from `/etc/os-release` to determine which version of oc-mirror to extract
        rhel_version=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release 2>/dev/null)

        ### Remove any existing oc-mirror binary before extracting the new one
        ### If an old `oc-mirror` binary exists, remove it to avoid conflicts with the new version
        if [[ -f "./oc-mirror" ]]; then
            echo "[INFO] Removing existing oc-mirror binary..."
            rm -f oc-mirror
        fi

        ### Extract the correct `oc-mirror` binary based on the RHEL version detected
        if [[ "$rhel_version" == "8" ]]; then
            if [[ -f "$OC_MIRROR_RHEL8_TAR" ]]; then
                extract_oc_mirror "$OC_MIRROR_RHEL8_TAR" "oc-mirror"
            fi
        elif [[ "$rhel_version" == "9" ]]; then
            if [[ -f "$OC_MIRROR_RHEL9_TAR" ]]; then
                extract_oc_mirror "$OC_MIRROR_RHEL9_TAR" "oc-mirror"
            fi
        else
            echo "ERROR: Unsupported RHEL version: 'rhel_version'. Exiting..."
            exit 1
        fi

        ### Set correct ownership and execute permissions for openshift tool binary
        if [[ -f "./oc-mirror" ]]; then
            echo "[INFO] Setting ownership and permissions for oc-mirror..."
            chown "$(whoami):$(id -gn)" ./oc-mirror
            chmod ug+x ./oc-mirror

            echo "[INFO] oc-mirror --v2 version"
            ./oc-mirror --v2 version
        fi
        ;;      
    "ocp")
        ### Handle OCP image mirroring for specified versions
        versions=("${version_range[@]}")

        ### Individual mode: Mirror each version separately
        for major_minor_patch in "${versions[@]}"; do
            oc_mirror_work_dir="$OCP_OLM_IMAGES_DIR/ocp/$major_minor_patch"
            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
                
            echo "[INFO]: Starting individual mirroring for OCP version: $major_minor_patch"
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$OCP_REPOSITORY"
            echo "[INFO]: Individual mirroring completed for OCP version: $major_minor_patch"
        done
        ;;
    "olm")
        ### Handle OLM image mirroring for specified catalogs
        if [[ -z "$OLM_CATALOGS" ]]; then
            ### If no catalogs are specified, exit with error
            echo "[ERROR]: OLM_CATALOGS is empty. Please specify catalogs (e.g., 'redhat--certified--community')."
            exit 1
        fi

        ### Extract unique major-minor versions from version_range
        major_minor_versions=($(printf '%s\n' "${version_range[@]}" | sed 's/[^0-9.]//g' | cut -d '.' -f 1,2 | sort -V -u))

        for catalog in "${catalogs[@]}"; do
            ### Set repository based on catalog type
            olm_repository=""
            if [[ "$catalog" == "redhat" ]]; then
                olm_repository="$OLM_REDHAT_REPOSITORY"
            elif [[ "$catalog" == "certified" ]]; then
                olm_repository="$OLM_CERTIFIED_REPOSITORY"
            elif [[ "$catalog" == "community" ]]; then
                olm_repository="$OLM_COMMUNITY_REPOSITORY"
            else
                echo "[WARN]: Unknown catalog: $catalog, skipping..."
                continue
            fi

            for major_minor in "${major_minor_versions[@]}"; do
                oc_mirror_work_dir="$OCP_OLM_IMAGES_DIR/olm/$catalog/$major_minor"
                imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

                echo "[INFO]: Starting individual mirroring for OLM catalog '$catalog' with version: $major_minor"
                mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$olm_repository"
                echo "[INFO]: Individual mirroring completed for OLM catalog '$catalog' with version: $major_minor"
            done
        done
        ;;
    "add")
        ### Handle additional image mirroring
        ### Process images in OCP_ADD_IMAGES_DIR
        if [[ -d "${OCP_ADD_IMAGES_DIR}" ]]; then
            ### Remove existing localhost images matching the pattern
            ls -1 ${OCP_ADD_IMAGES_DIR}/localhost_* \
                | awk -F'localhost_|.tar' '{print $2}' \
                | xargs -d "\n" -I {}  podman images {} | grep -v IMAGE \
                | awk '{print $1 ":" $2}' | sort -u \
                | xargs -I {} podman rmi {}

            ### Load images from tar files in OCP_ADD_IMAGES_DIR
            ls -1 ${OCP_ADD_IMAGES_DIR}/localhost_* | xargs -d '\n' -I {} podman load -i {}

            login_to_registry

            ### Tag and push localhost images to the mirror registry
            podman images | grep '^localhost' | awk '{print $1 ":" $2}' | while read -r image; do
                ### Create new tag with MIRROR_REGISTRY prefix
                new_tag="${MIRROR_REGISTRY}/${image#localhost/}"
                podman tag "$image" "$new_tag"
                podman push "$new_tag" --tls-verify=false
            done
        else
            ### If OCP_ADD_IMAGES_DIR does not exist, print error message
            echo "Error: Directory '${OCP_ADD_IMAGES_DIR}' does not exist. Please ensure the directory is set correctly."
        fi
        ;;
    *)
        ### Handle invalid image_type
        echo "[ERROR]: Invalid image_type: $image_type. Supported types: ocp, olm, add"
        exit 1
        ;;
esac