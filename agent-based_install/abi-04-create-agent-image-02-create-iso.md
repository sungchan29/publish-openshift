```bash

vi abi-04-create-agent-image-02-creage-iso.sh

```

```bash
#!/bin/bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..."
    exit 1
fi

if [[ -z "${OCP_VERSION}" ]]; then
    echo "Error: OCP_VERSION variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
    exit 1
fi

if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    if [[ -z "${MIRROR_REGISTRY}" ]]; then
        echo "Error: MIRROR_REGISTRY variable is empty. Exiting..."
        exit 1
    fi
    if [[ -z "${LOCAL_REPOSITORY_NAME}" ]]; then
        echo "Error: LOCAL_REPOSITORY_NAME variable is empty. Exiting..."
        exit 1
    fi

    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release-images:${OCP_VERSION}-x86_64
fi

# Check if the specified directory exists
if [[ ! -d "./${CLUSTER_NAME}/orig/openshift" ]]; then
    echo "ERROR: The directory or file './${CLUSTER_NAME}/orig/openshift' does not exist."
    echo "Please ensure the directory exists or execute the following command to create it:"
    echo "sh abi-03-create-file-04-vulnerability-mitigation-configs.sh"
    exit 1
fi

#####################
#####################
#####################

if [[ -f "./openshift-install" ]]; then
    ./openshift-install agent create image --dir ./${CLUSTER_NAME} --log-level debug

    if [[ -f "./${CLUSTER_NAME}/agent.x86_64.iso" ]]; then
        rm -f ./${CLUSTER_NAME}_agent.x86_64.iso
        mv ./${CLUSTER_NAME}/agent.x86_64.iso ./${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso
    fi
    tree
else
    echo "ERROR: The file './openshift-install' does not exist. Exiting..."
    echo "To resolve this issue, execute the following command:"
    echo "sh abi-02-install-openshift-tools.sh"
    exit 1
fi
```

```bash

sh abi-04-create-agent-image-02-creage-iso.sh

```