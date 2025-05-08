#!/bin/bash

### Define the OpenShift versions to mirror, separated by '--'
### These are the OCP versions that will be processed (e.g., 4.17.9, 4.17.15, 4.18.4)
OCP_VERSIONS="4.17.25"

### Define OLM (Operator Lifecycle Manager) catalogs to use, separated by '--'
### Examples include 'redhat', 'certified', 'community'; empty by default to set later
OLM_CATALOGS="redhat--certified"
OLM_CATALOGS="redhat"

### MIRROR_REGISTRY is the target registry URL where images will be pushed
MIRROR_REGISTRY="nexus.cloudpang.tistory.disconnected:5000"
### MIRROR_REGISTRY_USERNAME is the username for logging into the registry
MIRROR_REGISTRY_USERNAME="admin"

### Directory paths for OCP tools and images
OCP_TOOL_DIR="/root/ocp4/images-download/${OCP_VERSIONS}/export/tool-binaries"
OCP_TOOL_IMAGES_DIR="/root/ocp4/images-download/${OCP_VERSIONS}/export/additional-images"
OC_MIRROR_IMAGES_DIR="/root/ocp4/images-download/${OCP_VERSIONS}/export/oc-mirror"

### Strategy for mirroring
### Defines how images are mirrored: 'aggregated', 'incremental', or 'individual'; defaults later if not set
MIRROR_STRATEGY=""

### Repository paths for OCP and OLM images
### These define namespaces in the mirror registry; defaults set later if not specified
OCP_REPOSITORY=""
OLM_REDHAT_REPOSITORY=""
OLM_CERTIFIED_REPOSITORY=""
OLM_COMMUNITY_REPOSITORY=""

### Command path for oc-mirror tool
### Path to the oc-mirror binary; defaults to current directory if not set
OC_MIRROR_CMD=""

### Cache directory for oc-mirror
### Directory to store oc-mirror cache; defaults to user's home directory if not set
OC_MIRROR_CACHE_DIR=""


###
### Setup and Utility Functions
### Initialize configuration variables and define functions for OpenShift mirroring
###

### Check if oc-mirror tool exists
### Set default path for oc-mirror if not already defined
### If OC_MIRROR_CMD is empty, defaults to './oc-mirror' in the current directory
OC_MIRROR_CMD="${OC_MIRROR_CMD:-"$PWD/oc-mirror"}"


###
### Function to check if oc-mirror tool is available
###
check_oc_mirror() {
    ### Check if the oc-mirror binary exists at the specified path
    if [[ ! -f "$OC_MIRROR_CMD" ]]; then
        ### If oc-mirror is not found, print error and instructions, then exit
        echo "[ERROR]: 'oc-mirror' tool not found at $OC_MIRROR_CMD."
        echo "[INFO]: Please extract oc-mirror from $OCP_TOOL_DIR and place it in $PWD/."
        echo "[INFO]: Example commands:"
        echo "        tar -xzf $OCP_TOOL_DIR/oc-mirror.tar.gz -C $PWD/"
        echo "        chmod +x $OC_MIRROR_CMD"
        exit 1
    else
        ### If oc-mirror is found, print confirmation message
        echo "[INFO]: 'oc-mirror' tool found at $OC_MIRROR_CMD."
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
    ### Check if the command succeeded; exit with error if it failed
    if [[ $? -ne 0 ]]; then
        echo "[ERROR]: Failed to mirror images to $MIRROR_REGISTRY/$_repository"
        exit 1
    fi
}

### Get image type from script argument
image_type="$1"
### Check if image_type argument is provided
if [[ $# -ne 1 ]]; then
    ### If no argument is provided, print usage and exit
    echo "[ERROR]: Please provide an image type as an argument."
    echo "[USAGE]: $0 <image_type> (e.g., ocp, olm, add)"
    exit 1
fi

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
    ### Check if login succeeded; exit if it failed
    if [[ $? -ne 0 ]]; then
        echo "[ERROR]: Mirror Registry login failed."
        echo "[ERROR]: Please check your credentials and server address."
        exit 1
    fi
else
    ### If already logged in, print confirmation
    echo "[INFO]: Already logged into Mirror Registry: $MIRROR_REGISTRY"
fi

### Set default values for variables if not already defined
### OLM_CATALOGS defaults to 'redhat' if empty
OLM_CATALOGS="${OLM_CATALOGS:-"redhat"}"
### MIRROR_STRATEGY defaults to 'individual' if empty
MIRROR_STRATEGY="${MIRROR_STRATEGY:-"individual"}"
### OCP_REPOSITORY defaults to 'ocp4' if empty
OCP_REPOSITORY="${OCP_REPOSITORY:-"ocp4"}"
### OLM repository defaults for each catalog type
OLM_REDHAT_REPOSITORY="${OLM_REDHAT_REPOSITORY:-"olm-redhat"}"
OLM_CERTIFIED_REPOSITORY="${OLM_CERTIFIED_REPOSITORY:-"olm-certified"}"
OLM_COMMUNITY_REPOSITORY="${OLM_COMMUNITY_REPOSITORY:-"olm-community"}"

### Set default directories for binaries and images if not already defined
OCP_TOOL_DIR="${OCP_TOOL_DIR:-"$PWD/tool-binaries"}"
OCP_TOOL_IMAGES_DIR="${OCP_TOOL_IMAGES_DIR:-"$PWD/ocp-tool-images"}"
OC_MIRROR_IMAGES_DIR="${OC_MIRROR_IMAGES_DIR:-"$PWD"}"

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
    "ocp")
        ### Handle OCP image mirroring for specified versions
        versions=("${version_range[@]}")

        if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
            ### Aggregated mode: Mirror all versions in a single operation
            oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/ocp/$MIRROR_STRATEGY"
            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

            echo "[INFO]: Starting aggregated mirroring for OCP versions: $OCP_VERSIONS"
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$OCP_REPOSITORY"
            echo "[INFO]: Aggregated mirroring completed for OCP versions: $OCP_VERSIONS"
        elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
            ### Incremental mode: Mirror versions step-by-step
            for ((i=0; i<${#versions[@]}; i++)); do
                ### Take versions up to the current index
                current_versions=("${versions[@]:0:$((i+1))}")
                ### Convert array to string with '--' separator
                version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

                oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/ocp/$MIRROR_STRATEGY/$version_string"
                imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"
                
                echo "[INFO]: Starting incremental mirroring for OCP versions: $version_string"
                mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$OCP_REPOSITORY"
                echo "[INFO]: Incremental mirroring completed for OCP versions: $version_string"
            done
        elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
            ### Individual mode: Mirror each version separately
            for major_minor_patch in "${versions[@]}"; do
                oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/ocp/$MIRROR_STRATEGY/$major_minor_patch"
                imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
                
                echo "[INFO]: Starting individual mirroring for OCP version: $major_minor_patch"
                mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$OCP_REPOSITORY"
                echo "[INFO]: Individual mirroring completed for OCP version: $major_minor_patch"
            done
        else
            ### Handle invalid MIRROR_STRATEGY
            echo "[ERROR]: Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'."
            exit 1
        fi
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

        if [[ "$MIRROR_STRATEGY" == "aggregated" ]]; then
            ### Aggregated mode: Mirror all versions for each catalog in a single operation
            for catalog in "${catalogs[@]}"; do
                oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/olm/$catalog/$MIRROR_STRATEGY"
                imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"
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

                echo "[INFO]: Starting aggregated mirroring for OLM catalog '$catalog' with versions: $major_minor_versions"
                mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$olm_repository"
                echo "[INFO]: Aggregated mirroring completed for OLM catalog '$catalog'"
            done
        elif [[ "$MIRROR_STRATEGY" == "incremental" ]]; then
            ### Incremental mode: Mirror versions step-by-step for each catalog
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
                ### Generate files incrementally
                for ((i=0; i<${#major_minor_versions[@]}; i++)); do
                    current_versions=("${major_minor_versions[@]:0:$((i+1))}")
                    version_string=$(echo "${current_versions[@]}" | sed 's/ /--/g')

                    oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/olm/$catalog/$MIRROR_STRATEGY/$version_string"
                    imageset_config_file="$oc_mirror_work_dir/imageset-config-${version_string}.yaml"

                    echo "[INFO]: Starting incremental mirroring for OLM catalog '$catalog' with version: $version_string"
                    mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$olm_repository"
                    echo "[INFO]: Incremental mirroring completed for OLM catalog '$catalog' with versions: $version_string"
                done
            done
        elif [[ "$MIRROR_STRATEGY" == "individual" ]]; then
            ### Individual mode: Mirror each version separately for each catalog
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
                    oc_mirror_work_dir="$OC_MIRROR_IMAGES_DIR/olm/$catalog/$MIRROR_STRATEGY/$major_minor"
                    imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

                    echo "[INFO]: Starting individual mirroring for OLM catalog '$catalog' with version: $major_minor"
                    mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$olm_repository"
                    echo "[INFO]: Individual mirroring completed for OLM catalog '$catalog' with version: $major_minor"
                done
            done
        else
            ### Handle invalid MIRROR_STRATEGY
            echo "[ERROR]: Invalid MIRROR_STRATEGY value: $MIRROR_STRATEGY. Must be 'aggregated', 'incremental', or 'individual'."
            exit 1
        fi
        ;;
    "add")
        ### Handle additional image mirroring
        ### Process images in OCP_TOOL_IMAGES_DIR
        if [[ -d "${OCP_TOOL_IMAGES_DIR}" ]]; then
            ### Remove existing localhost images matching the pattern
            ls -1 ${OCP_TOOL_IMAGES_DIR}/localhost_* \
                | awk -F'localhost_|.tar' '{print $2}' \
                | xargs -d "\n" -I {}  podman images {} | grep -v IMAGE \
                | awk '{print $1 ":" $2}' | sort -u \
                | xargs -I {} podman rmi {}

            ### Load images from tar files in OCP_TOOL_IMAGES_DIR
            ls -1 ${OCP_TOOL_IMAGES_DIR}/localhost_* | xargs -d '\n' -I {} podman load -i {}

            ### Tag and push localhost images to the mirror registry
            podman images | grep '^localhost' | awk '{print $1 ":" $2}' | while read -r image; do
                ### Create new tag with MIRROR_REGISTRY prefix
                new_tag="${MIRROR_REGISTRY}/${image#localhost/}"
                podman tag "$image" "$new_tag"
                podman push "$new_tag" --tls-verify=false
            done
        else
            ### If OCP_TOOL_IMAGES_DIR does not exist, print error message
            echo "Error: Directory '${OCP_TOOL_IMAGES_DIR}' does not exist. Please ensure the directory is set correctly."
        fi
        ;;
    *)
        ### Handle invalid image_type
        echo "[ERROR]: Invalid image_type: $image_type. Supported types: ocp, olm, add"
        exit 1
        ;;
esac

### Indicate successful completion of the script
echo "[INFO]: Mirroring completed successfully."