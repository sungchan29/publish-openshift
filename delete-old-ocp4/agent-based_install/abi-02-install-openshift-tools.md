
```bash

vi abi-02-install-openshift-tools.sh

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
if [[ ! -d "${DOWNLOAD_DIRECTORY}" ]]; then
    echo "Error: DOWNLOAD_DIRECTORY variable is empty or not a directory."
    exit 1
fi

#####################
#####################
#####################

openshift_install_file="openshift-install-linux-v${OCP_VERSION}.tar.gz"
if [[ -f ${DOWNLOAD_DIRECTORY}/${openshift_install_file} ]]; then
    if [[ -f ./openshift-install ]]; then
        rm -f ./openshift-install
    fi
    tar --exclude='README.md' -xvf ${DOWNLOAD_DIRECTORY}/${openshift_install_file} -C ./
    chmod ug+x ./openshift-install
    ./openshift-install version
    echo ""
fi

RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
openshift_client_file=""
if [[ "$RHEL_VERSION" == "8" ]]; then
    openshift_client_file="openshift-client-linux-amd64-rhel8-v${OCP_VERSION}.tar.gz"
elif [[ "$RHEL_VERSION" == "9" ]]; then
    openshift_client_file="openshift-client-linux-amd64-rhel9-v${OCP_VERSION}.tar.gz"
fi
if [[ -f ${DOWNLOAD_DIRECTORY}/${openshift_client_file} ]]; then
    if [[ -f ./oc ]]; then
        rm -f ./oc
    fi
    tar --exclude='README.md' -xvf ${DOWNLOAD_DIRECTORY}/${openshift_client_file} -C ./
    chmod ug+x ./oc
    ./oc version --client
    echo ""
fi

if [[ -f ${DOWNLOAD_DIRECTORY}/butane ]]; then
    if [[ -f ./butane ]]; then
        rm -f ./butane
    fi
    cp ${DOWNLOAD_DIRECTORY}/butane ./
    chmod ug+x ./butane
    ./butane --version
fi
```


```bash

sh abi-02-install-openshift-tools.sh

```
