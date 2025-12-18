#!/bin/bash

### ---------------------------------------------------------------------------------
### Image Mirroring Utility Script
### ---------------------------------------------------------------------------------
### This script is a master utility for mirroring OpenShift assets. It can install
### the 'oc-mirror' tool and mirror OCP release images, OLM operators, and
### additional images to a disconnected registry based on a command-line argument.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Configuration Variables (User Defined)
### ---------------------------------------------------------------------------------
### Specifies the OpenShift versions to mirror, separated by '--'.
OCP_VERSIONS="4.20.6"

### Specifies the OLM (Operator Lifecycle Manager) catalogs to use, separated by '--'.
OLM_CATALOGS="redhat--certified"

### Defines the connection details for the local mirror registry.
MIRROR_REGISTRY="registry.cloudpang.lan:5000"
MIRROR_REGISTRY_USERNAME="admin"

### Defines the base directory paths for source files.
INSTALL_FILES_BASE_DIR="/root/ocp4/download/4.20.6"
OCP_OLM_IMAGES_DIR="$INSTALL_FILES_BASE_DIR/export/oc-mirror"
OCP_ADD_IMAGES_DIR="$INSTALL_FILES_BASE_DIR/export/additional-images"
OC_MIRROR_TOOL_DIR="$INSTALL_FILES_BASE_DIR/export/tool-binaries"

### Defines the full paths to the 'oc-mirror' tool tarballs.
OC_MIRROR_RHEL8_TAR="$OC_MIRROR_TOOL_DIR/oc-mirror.tar.gz"
OC_MIRROR_RHEL9_TAR="$OC_MIRROR_TOOL_DIR/oc-mirror.rhel9.tar.gz"

### Defines the target repository names within the mirror registry.
OCP_REPOSITORY=""
OLM_REDHAT_REPOSITORY=""
OLM_CERTIFIED_REPOSITORY=""
OLM_COMMUNITY_REPOSITORY=""

### Defines the cache directory for 'oc-mirror'.
OC_MIRROR_CACHE_DIR=""

######################################################################################
###                 INTERNAL LOGIC - DO NOT MODIFY BELOW THIS LINE                 ###
######################################################################################

### Sets default values for variables if they are not already defined.
OCP_REPOSITORY="${OCP_REPOSITORY:-"ocp4"}"
OLM_REDHAT_REPOSITORY="${OLM_REDHAT_REPOSITORY:-"olm-redhat"}"
OLM_CERTIFIED_REPOSITORY="${OLM_CERTIFIED_REPOSITORY:-"olm-certified"}"
OLM_COMMUNITY_REPOSITORY="${OLM_COMMUNITY_REPOSITORY:-"olm-community"}"

OC_MIRROR_CMD="${OC_MIRROR_CMD:-"$PWD/oc-mirror"}"
OC_MIRROR_CACHE_DIR="${OC_MIRROR_CACHE_DIR:-"$PWD"}"

### ---------------------------------------------------------------------------------
### Utility Functions
### ---------------------------------------------------------------------------------

### Extracts the 'oc-mirror' binary from a specified tar file.
extract_oc_mirror() {
    local file="$1"
    local tool="$2"

    printf "%-8s%-80s\n" "[INFO]" "--- Extracting '$tool' from '$(basename "$file")'..."

    local CMD_ARGS=("tar" "xf" "$file" "-C" "./" "$tool")

    printf "%-8s%-80s\n" "[INFO]" "    Command: ${CMD_ARGS[*]}"
    "${CMD_ARGS[@]}" || {
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to extract '$file'. Exiting..."
        exit 1
    }
}

### Validates that the 'oc-mirror' binary is present.
check_oc_mirror() {
    if [[ ! -f "$OC_MIRROR_CMD" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "    The 'oc-mirror' binary was not found at '$OC_MIRROR_CMD'. Exiting..."
        exit 1
    fi
}

### Checks for an active Podman login to the mirror registry and prompts for login if needed.
login_to_registry() {
    printf "%-8s%-80s\n" "[INFO]" "    Checking login status for mirror registry '$MIRROR_REGISTRY'..."

    if ! podman login --tls-verify=false --get-login "$MIRROR_REGISTRY" >/dev/null 2>&1; then
        printf "%-8s%-80s\n" "[INFO]" "    Not logged in. Attempting login for user '$MIRROR_REGISTRY_USERNAME'..."
        if [[ -t 0 ]]; then
            podman login --tls-verify=false -u "$MIRROR_REGISTRY_USERNAME" "$MIRROR_REGISTRY"
        else
            printf "%-8s%-80s\n" "[ERROR]" "    Non-interactive shell detected. Cannot prompt for password. Please log in manually. Exiting..."
            exit 1
        fi
    else
        printf "%-8s%-80s\n" "[INFO]" "    Already logged into the mirror registry."
    fi
}

### Executes the 'oc-mirror' command to push a local image set to the mirror registry.
mirror_images() {
    local _imageset_config_file="$1"
    local _oc_mirror_work_dir="$2"
    local _repository="$3"

    check_oc_mirror
    login_to_registry

    printf "%-8s%-80s\n" "[INFO]" "    -- Starting 'oc-mirror' push to registry..."
    printf "%-8s%-80s\n" "[INFO]" "       - Config File      : $_imageset_config_file"
    printf "%-8s%-80s\n" "[INFO]" "       - Source Directory : $_oc_mirror_work_dir"
    printf "%-8s%-80s\n" "[INFO]" "       - Target Repository: $_repository"

    if [[ ! -f "$_imageset_config_file" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       ImageSet configuration file not found: '$_imageset_config_file'. Exiting..."
        exit 1
    fi
    if [[ ! -d "$_oc_mirror_work_dir/working-dir" ]]; then
        printf "%-8s%-80s\n" "[ERROR]" "       Mirror source directory not found: '$_oc_mirror_work_dir/working-dir'. Exiting..."
        exit 1
    fi

    local CMD_ARGS=(
        "$OC_MIRROR_CMD" "--v2"
        "--dest-tls-verify=false"
        "--cache-dir" "$OC_MIRROR_CACHE_DIR"
        "--config" "$_imageset_config_file"
        "--from" "file://$_oc_mirror_work_dir"
        "docker://$MIRROR_REGISTRY/$_repository"
    )

    printf "%-8s%-80s\n" "[INFO]" "    Command to be executed:"
    printf "%-8s%-80s\n" "[INFO]" "    ${CMD_ARGS[*]}"

    "${CMD_ARGS[@]}" || {
        printf "%-8s%-80s\n" "[ERROR]" "    'oc-mirror' execution failed."
        exit 1
    }
}

### ---------------------------------------------------------------------------------
### Main Execution
### ---------------------------------------------------------------------------------
### Validate that exactly one command-line argument (the image type) is provided.
if [[ $# -ne 1 ]]; then
    echo ""
    printf "%-8s%-80s\n" "[INFO]" "An image type must be provided as a single argument."
    printf "%-8s%-80s\n" "[INFO]" "Usage: $0 <type> (where type is one of: tool, ocp, olm, add)"
    echo ""
    exit 1
fi

# After the check passes, assign the argument to the variable.
image_type="$1"

### Parse OCP versions and catalogs from configuration strings into arrays.
IFS='|' read -r -a version_range <<< "${OCP_VERSIONS//--/|}"
IFS='|' read -r -a catalogs      <<< "${OLM_CATALOGS//--/|}"
unset IFS

### Execute the requested action based on the 'image_type' argument.
case "$image_type" in
    "tool")
        printf "%-8s%-80s\n" "[INFO]" "=== Installing 'oc-mirror' Tool ==="

        ### Detect RHEL Version
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            rhel_version="${VERSION_ID%%.*}"
        else
            rhel_version="unknown"
        fi

        ### Remove any existing 'oc-mirror' binary to prevent conflicts.
        if [[ -f "./oc-mirror" ]]; then
            printf "%-8s%-80s\n" "[INFO]" "--- Removing existing './oc-mirror' binary..."
            rm -f oc-mirror
        fi

        if [[ "$rhel_version" == "8" ]]; then
            extract_oc_mirror "$OC_MIRROR_RHEL8_TAR" "oc-mirror"
        elif [[ "$rhel_version" == "9" ]]; then
            extract_oc_mirror "$OC_MIRROR_RHEL9_TAR" "oc-mirror"
        else
            printf "%-8s%-80s\n" "[ERROR]" "    Unsupported RHEL version detected: '$rhel_version'. Exiting..."
            exit 1
        fi

        ### Verify that the binary was extracted successfully.
        if [[ ! -f "./oc-mirror" ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Failed to extract 'oc-mirror' binary. Please check the archive file. Exiting..."
            exit 1
        fi
        chmod ug+x ./oc-mirror

        printf "%-8s%-80s\n" "[INFO]" "    Verification:"
        ./oc-mirror --v2 version
        ;;

    "ocp")
        printf "%-8s%-80s\n" "[INFO]" "=== Mirroring OCP Release Images ==="
        for major_minor_patch in "${version_range[@]}"; do
            oc_mirror_work_dir="$OCP_OLM_IMAGES_DIR/ocp/$major_minor_patch"
            imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

            printf "%-8s%-80s\n" "[INFO]" "--- Mirroring OCP release for version '$major_minor_patch'..."
            mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$OCP_REPOSITORY"
        done
        ;;

    "olm")
        printf "%-8s%-80s\n" "[INFO]" "=== Mirroring OLM Operator Images ==="
        if [[ -z "$OLM_CATALOGS" ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    The 'OLM_CATALOGS' variable is not set. Cannot mirror OLM images. Exiting..."
            exit 1
        fi

        ### Parse Major.Minor versions using sed/cut as per original logic
        major_minor_versions=($(printf '%s\n' "${version_range[@]}" | sed 's/[^0-9.]//g' | cut -d '.' -f 1,2 | sort -V -u))

        for catalog in "${catalogs[@]}"; do
            olm_repository=""
            case "$catalog" in
                "redhat")    olm_repository="$OLM_REDHAT_REPOSITORY"    ;;
                "certified") olm_repository="$OLM_CERTIFIED_REPOSITORY" ;;
                "community") olm_repository="$OLM_COMMUNITY_REPOSITORY" ;;
                *) printf "%-8s%-80s\n" "[WARN]" "    Unknown catalog type '$catalog'. Skipping."; continue ;;
            esac

            for major_minor in "${major_minor_versions[@]}"; do
                oc_mirror_work_dir="$OCP_OLM_IMAGES_DIR/olm/$catalog/$major_minor"
                imageset_config_file="$oc_mirror_work_dir/imageset-config.yaml"

                printf "%-8s%-80s\n" "[INFO]" "--- Mirroring OLM catalog '$catalog' for OCP v$major_minor..."
                mirror_images "$imageset_config_file" "$oc_mirror_work_dir" "$olm_repository"
            done
        done
        ;;

    "add")
        printf "%-8s%-80s\n" "[INFO]" "=== Mirroring Additional Images ==="
        if [[ ! -d "${OCP_ADD_IMAGES_DIR}" ]]; then
            printf "%-8s%-80s\n" "[ERROR]" "    Additional images directory '${OCP_ADD_IMAGES_DIR}' not found. Exiting..."
            exit 1
        fi
        login_to_registry
        printf "%-8s%-80s\n" "[INFO]" "--- Loading, tagging, and pushing images from '${OCP_ADD_IMAGES_DIR}'..."

        ### Sequentially load, tag, and push for each tar file found by 'find'.
        ### Using process substitution to safely handle file names with spaces
        while IFS= read -r -d $'\0' tar_file; do
            filename=$(basename "$tar_file")
            printf "%-8s%-80s\n" "[INFO]" "    -- Loading image from '$filename'..."

            ### Capture output to find loaded image name
            load_out=$(podman load -i "$tar_file")
            ### Extract just the image names (e.g., "Loaded image: localhost/image:tag")
            loaded_images=$(echo "$load_out" | grep "Loaded image" | awk '{print $3}')

            if [[ -z "$loaded_images" ]]; then
                printf "%-8s%-80s\n" "[WARN]" "      No images were loaded from '$filename'. Skipping."
                continue
            fi

            ### Tag and push only the images that were just loaded.
            for image in $loaded_images; do
                ### Remove localhost/ prefix
                new_tag="${MIRROR_REGISTRY}/${image#localhost/}"

                printf "%-8s%-80s\n" "[INFO]" "       Tagging image '$image' to '$new_tag'..."

                ### [FIXED] Removed 'local' keyword (Global Scope)
                CMD_TAG=("podman" "tag" "$image" "$new_tag")
                "${CMD_TAG[@]}" || {
                    printf "%-8s%-80s\n" "[ERROR]" "       Failed to tag image. Skipping..." >&2
                    continue 2
                }

                printf "%-8s%-80s\n" "[INFO]" "       Pushing image '$new_tag'..."

                ### [FIXED] Removed 'local' keyword (Global Scope)
                CMD_PUSH=("podman" "push" "--tls-verify=false" "$new_tag")
                if "${CMD_PUSH[@]}"; then
                     printf "%-8s%-80s\n" "[INFO]" "       Push successful."
                else
                     printf "%-8s%-80s\n" "[ERROR]" "       Failed to push image. Skipping..." >&2
                     continue 2
                fi
            done
        done < <(find "${OCP_ADD_IMAGES_DIR}" -maxdepth 1 -name "localhost_*.tar" -print0)
        ;;

    *)
        echo ""
        printf "%-8s%-80s\n" "[INFO]" "An image type must be provided as a single argument."
        printf "%-8s%-80s\n" "[INFO]" "Usage: $0 <type> (where type is one of: tool, ocp, olm, add)"
        echo ""
        exit 1
        ;;
esac
echo ""