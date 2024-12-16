
```bash

vi bastion-02-install-openshift-tools.sh

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

os_user="$(whoami)"

if [[ "$os_user" == "root" ]]; then
    # Set OCP_TOOLS_DIR to /usr/local/bin if it exists in PATH
    OCP_TOOLS_DIR=$(echo $PATH | tr ':' '\n' | grep "/usr/local/bin")

    if [[ -z $OCP_TOOLS_DIR ]]; then
        OCP_TOOLS_DIR=$(echo $PATH | tr ':' '\n' | grep "/usr/local/sbin")
    fi
else
    # Set OCP_TOOLS_DIR to the user’s bin directory if it exists in PATH
    OCP_TOOLS_DIR=$(echo $PATH | tr ':' '\n' | grep "$os_user" | grep "$HOME/bin")
fi
# Create the directory if it does not exist
if [[ -n "$OCP_TOOLS_DIR" && ! -d "$OCP_TOOLS_DIR" ]]; then
    mkdir -p "$OCP_TOOLS_DIR"
fi

# Confirm OCP_TOOLS_DIR is set and a directory
if [[ ! -d "$OCP_TOOLS_DIR" ]]; then
    echo "Error: OCP_TOOLS_DIR variable is empty or not a directory."
    exit 1
fi

# Check if the directory has write permissions for both user and group
if [[ -w "$OCP_TOOLS_DIR" && $(stat -c "%A" "$OCP_TOOLS_DIR") =~ ^..w ]]; then
    echo "$OCP_TOOLS_DIR : The directory has write permissions for user and group."
    echo ""
else
    echo "Error: $OCP_TOOLS_DIR"
    echo "Error: The directory does not have sufficient write permissions for user or group. Exiting..."
    exit 1
fi

RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
OPENSHIFT_CLIENT_FILE=""
if [[ "$RHEL_VERSION" == "8" ]]; then
    OPENSHIFT_CLIENT_FILE="$(echo ${OPENSHIFT_CLIENT_RHEL8_FILE} | awk -F '.' '{print $1}')-v${OCP_TARGET_VERSION}.tar.gz"
elif [[ "$RHEL_VERSION" == "9" ]]; then
    OPENSHIFT_CLIENT_FILE="$(echo ${OPENSHIFT_CLIENT_RHEL9_FILE} | awk -F '.' '{print $1}')-v${OCP_TARGET_VERSION}.tar.gz"
fi

if [[ -f ${DOWNLOAD_DIRECTORY}/${OPENSHIFT_CLIENT_FILE} ]]; then
    echo "### ${DOWNLOAD_DIRECTORY}/${OPENSHIFT_CLIENT_FILE}"

    if [[ -f $OCP_TOOLS_DIR/oc ]]; then
        rm -f $OCP_TOOLS_DIR/oc
    fi
    if [[ -f $OCP_TOOLS_DIR/kubectl ]]; then
        rm -f $OCP_TOOLS_DIR/kubectl
    fi

    ocp_tool=$(which oc)
    if [[ -f $ocp_tool ]]; then
        rm -f $ocp_tool
    fi
    ocp_tool=$(which kubectl)
    if [[ -f $ocp_tool ]]; then
        rm -f $ocp_tool
    fi

    tar --exclude='README.md' -xvf ${DOWNLOAD_DIRECTORY}/${OPENSHIFT_CLIENT_FILE} -C ${OCP_TOOLS_DIR}
    chmod ug+x ${OCP_TOOLS_DIR}/oc
    echo -n "oc version: "
    ${OCP_TOOLS_DIR}/oc version --client
    echo -n "kubectl version: "
    ${OCP_TOOLS_DIR}/kubectl version --client
    echo ""
fi
if [[ -f ${DOWNLOAD_DIRECTORY}/butane ]]; then
    echo "### ${DOWNLOAD_DIRECTORY}/butane"
    if [[ -f $OCP_TOOLS_DIR/butane ]]; then
        rm -f $OCP_TOOLS_DIR/butane
    fi
    ocp_tool=$(which butane)
    if [[ -f $ocp_tool ]]; then
       rm -f $ocp_tool
    fi

    cp ${DOWNLOAD_DIRECTORY}/butane ${OCP_TOOLS_DIR}/
    chmod ug+x ${OCP_TOOLS_DIR}/butane
fi

ls -al ${OCP_TOOLS_DIR}/
```



```bash

sh bastion-02-install-openshift-tools.sh

```
