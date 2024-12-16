```bash

vi bastion-03-push-openshift-tools.sh

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

ls -1 ${DOWNLOAD_DIRECTORY}/localhost_* \
  | awk -F'localhost_|.tar' '{print $2}' \
  | xargs -d "\n" -I {}  podman images {} | grep -v IMAGE \
  | awk '{print $1 ":" $2}' | sort -u \
  | xargs -I {} podman rmi {}

ls -1 ${DOWNLOAD_DIRECTORY}/localhost_* | xargs -d '\n' -I {} podman load -i {}

podman images | grep '^localhost' | awk '{print $1 ":" $2}' | while read -r image; do
    new_tag="${MIRROR_REGISTRY}/${image#localhost/}"
    podman tag "$image" "$new_tag"
    podman push $new_tag
done
```


```bash

sh bastion-03-push-openshift-tools.sh

```