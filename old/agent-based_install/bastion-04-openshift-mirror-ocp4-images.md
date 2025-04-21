```bash

vi bastion-04-openshift-mirror-ocp4-images.sh

```


```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/bastion-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/bastion-01-config-preparation.sh"
else
    echo "ERROR: Cannot access '$(dirname "$0")/bastion-01-config-preparation.sh'. File or directory does not exist. Exiting..."
    exit 1
fi
#############################
### Variable Override Section

#############################

if [[ -z "${OCP_UPDATE_PATH}" ]]; then
    echo "Error: OCP_UPDATE_PATH variable is empty. Exiting..."
    exit 1
fi
if [[ ! -d "${DOWNLOAD_DIRECTORY}" ]]; then
    echo "Error: DOWNLOAD_DIRECTORY variable is empty or not a directory."
    exit 1
fi
if [[ -z $MIRROR_REGISTRY ]]; then
    echo "Error: MIRROR_REGISTRY variable is empty. Exiting..."
    exit 1
fi

if [[ ! -f ./oc-mirror ]]; then
    rhel_version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
    oc_mirror_file=""
    if [[ "$rhel_version" == "8" ]]; then
        oc_mirror_file="$OC_MIRROR_RHEL8_FILE"
    elif [[ "$rhel_version" == "9" ]]; then
        oc_mirror_file="$OC_MIRROR_RHEL9_FILE"
    fi

    if [[ -f ${DOWNLOAD_DIRECTORY}/$oc_mirror_file ]]; then
        echo "### ${DOWNLOAD_DIRECTORY}/$oc_mirror_file"

        tar -xvf ${DOWNLOAD_DIRECTORY}/$oc_mirror_file -C ./
        chmod ug+x ./oc-mirror
        echo -n "./oc-mirror version: "
        ./oc-mirror version
        echo ""
    else
        echo "${DOWNLOAD_DIRECTORY}/$oc_mirror_file file does not exist."
        exit 1
    fi
fi

# Attempt to login based on the presence of USERNAME and PASSWORD
if [[ -n $USERNAME ]]; then
    if [[ -n $PASSWORD ]]; then
        podman login $MIRROR_REGISTRY -u "$USERNAME" -p "$PASSWORD"
    else
        podman login $MIRROR_REGISTRY -u "$USERNAME"
    fi
else
    # If no USERNAME, login without user
    podman login $MIRROR_REGISTRY
fi

# Check the exit status of the login command
if [[ $? -ne 0 ]]; then
    echo "Error: Podman login failed. Exiting..."
    exit 1
fi

OCP_UPDATE_PATH=$(echo "$OCP_UPDATE_PATH" | sed 's/--/|/g')

# Split OCP_UPDATE_PATH into an array by '|'
IFS='|' read -r -a versions <<< "$OCP_UPDATE_PATH"

unset min_versions
unset max_versions

declare -A min_versions
declare -A max_versions
declare -A prefixes

if [[ -f .oc-mirror.log ]]; then
    rm -f .oc-mirror.log
fi

# Process each version
for version in "${versions[@]}"; do
    # Initialize prefix as 'stable' by default
    prefix="stable"

    # Check if the version is an EUS version
    if [[ "$version" == eus-* ]]; then
        version=${version#eus-}  # Remove 'eus-' prefix for processing
        prefix="eus"
    fi
    # Split into major.minor and patch
    major_minor=$(echo "$version" | cut -d '.' -f 1,2)
    patch=$(echo "$version" | cut -d '.' -f 3)

    # Skip if major_minor or patch is empty
    if [[ -z "$major_minor" ]] || [[ -z "$patch" ]]; then
        continue
    fi

    ocp_mirror_image="$(find "${DOWNLOAD_DIRECTORY}" -type f -name "ocp4-v${version}_mirror_seq*")"
    if [[ -f $ocp_mirror_image ]]; then
        ./oc-mirror --from=./${ocp_mirror_image} docker://${MIRROR_REGISTRY}/ocp4 --skip-pruning
    fi
done
```


```bash

nohup sh bastion-04-openshift-mirror-ocp4-images.sh > /dev/null 2>&1 &

```