```bash

vi bastion-05-openshift-mirror-ocp4-operator-images.sh

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

olm_mirror_images="$(find "${DOWNLOAD_DIRECTORY}" -type f -name "olm-*-v${OCP_UPDATE_PATH}_mirror_seq*")"
for olm_mirror_image_file in $olm_mirror_images; do
    if [[ -f $olm_mirror_image_file ]]; then
        olm_namespace=$(basename "$olm_mirror_image_file" | sed -E "s/(-v${OCP_UPDATE_PATH}).*//")
        ./oc-mirror --from="./$olm_mirror_image_file" "docker://${MIRROR_REGISTRY}/${olm_namespace}" --rebuild-catalogs
    fi
done
```


```bash

nohup sh bastion-05-openshift-mirror-ocp4-operator-images.sh > /dev/null 2>&1 &

```