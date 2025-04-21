
```bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..."
#    exit 1
fi

if [[ -z "${OCP_VERSION}" ]]; then
    echo "Error: OCP_VERSION variable is empty. Exiting..."
#    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
#    exit 1
fi

#####################
#####################
#####################

ls -al /var/lib/libvirt/images/

ISO_FILES="$(ls /var/lib/libvirt/images/${CLUSTER_NAME}*_agent.x86_64.iso)"
for iso_file in "$ISO_FILES"; do
    if [[ -f "$iso_file" ]]; then
        rm -f $iso_file
    fi
done

if [[ -f "./${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso" ]]; then
    if [[ -f "/var/lib/libvirt/images/${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso" ]]; then
        rm -f /var/lib/libvirt/images/${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso
        ls -al /var/lib/libvirt/images/
    fi

    cp -f ./${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso /var/lib/libvirt/images/

    ls -al /var/lib/libvirt/images/
fi

```


```bash

# Source the abi-01-config-preparation-01-general.sh file
if [[ -f ./abi-01-config-preparation-01-general.sh ]]; then
    source "./abi-01-config-preparation-01-general.sh"
else
    echo "ERROR: Cannot access './abi-01-config-preparation-01-general.sh'. File or directory does not exist. Exiting..."
#    exit 1
fi

if [[ -z "${OCP_VERSION}" ]]; then
    echo "Error: OCP_VERSION variable is empty. Exiting..."
#    exit 1
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
#    exit 1
fi

VM_NETWORK_01="bridge=bridge0,model=virtio"
VM_IMAGES_PATH="/var/lib/libvirt/images"
RHCOS_AGENT_ISO_FILE="/var/lib/libvirt/images/${CLUSTER_NAME}-v${OCP_VERSION}_agent.x86_64.iso"

VM_INFO_LIST=" \
  sno--20--49152--52:54:00:7d:e1:09 \
"

#####################
#####################
#####################


for vminfo in ${VM_INFO_LIST}; do
    NAME=$(       echo $vminfo |awk -F "--" '{print $1}')
    CPU=$(        echo $vminfo |awk -F "--" '{print $2}')
    MEMORY=$(     echo $vminfo |awk -F "--" '{print $3}')
    MAC_ADDRESS=$(echo $vminfo |awk -F "--" '{print $4}')

    nohup \
    virt-install \
      --connect     qemu:///system \
      --name        ${NAME} \
      --cpu         host \
      --vcpus       ${CPU} \
      --memory      ${MEMORY} \
      --disk        ${VM_IMAGES_PATH}/${NAME}-01.qcow2,size=100,bus=virtio \
      --cdrom       ${RHCOS_AGENT_ISO_FILE} \
      --network     ${VM_NETWORK_01},mac=${MAC_ADDRESS} \
      --boot        hd \
      --os-variant  rhel9-unknown \
      --noautoconsole \
      --wait \
      > ${NAME}_virt-install.log 2>&1 &
done

```


```bash

CLUSTER_NAME="cloudpang"

VM_NETWORK_01="bridge=bridge0,model=virtio"
VM_IMAGES_PATH="/var/lib/libvirt/images"
RHCOS_AGENT_ISO_FILE="/var/lib/libvirt/images/${CLUSTER_NAME}_agent.x86_64.iso"

VM_INFO_LIST=" \
  master01--8--16384--52:54:00:7d:e1:11 \
  master02--8--16384--52:54:00:7d:e1:12 \
  master03--8--16384--52:54:00:7d:e1:13 \
"

for vminfo in ${VM_INFO_LIST}; do
    NAME=$(       echo $vminfo |awk -F "--" '{print $1}')
    CPU=$(        echo $vminfo |awk -F "--" '{print $2}')
    MEMORY=$(     echo $vminfo |awk -F "--" '{print $3}')
    MAC_ADDRESS=$(echo $vminfo |awk -F "--" '{print $4}')

    nohup \
    virt-install \
      --connect     qemu:///system \
      --name        ${NAME} \
      --cpu         host \
      --vcpus       ${CPU} \
      --memory      ${MEMORY} \
      --disk        ${VM_IMAGES_PATH}/${NAME}-01.qcow2,size=100,bus=virtio \
      --cdrom       ${RHCOS_AGENT_ISO_FILE} \
      --network     ${VM_NETWORK_01},mac=${MAC_ADDRESS} \
      --boot        hd \
      --os-variant  rhel9-unknown \
      --noautoconsole \
      --wait \
      > ${NAME}_virt-install.log 2>&1 &
done

```