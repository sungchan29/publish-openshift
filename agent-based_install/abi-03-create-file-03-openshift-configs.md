```bash

vi abi-03-create-file-03-openshift-configs.sh

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

if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Error: CLUSTER_NAME variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${OCP_VERSION}" ]]; then
    echo "Error: OCP_VERSION variable is empty. Exiting..."
    exit 1
fi


if [[ -z "${NODE_ROLE_SELECTORS}" ]]; then
    echo "Error: NODE_ROLE_SELECTORS variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${OLM_OPERATORS}" ]]; then
    echo "Error: OLM_OPERATORS variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${NTP_SERVER_01}" ]]; then
    echo "Error: NTP_SERVER_01 variable is empty. Exiting..."
    exit 1
fi

if [[ -n "${ADD_DEVICE_NAME}" ]]; then
    if [[ -z "${FILESYSTEM_PATH}" ]]; then
        echo "Error: FILESYSTEM_PATH variable is empty. Exiting..."
        exit 1
    fi
    if [[ "PARTITION" = "${ADD_DEVICE_TYPE}" ]]; then
        if [[ -z "${PARTITION_LABEL}" ]]; then
            echo "Error: PARTITION_LABEL variable is empty. Exiting..."
            exit 1
        fi
        if [[ -z "${PARTITION_START_MIB}" ]]; then
            echo "Error: PARTITION_START_MIB variable is empty. Exiting..."
            exit 1
        fi
        if [[ -z "${PARTITION_SIZE_MIB}" ]]; then
            echo "Error: PARTITION_SIZE_MIB variable is empty. Exiting..."
            exit 1
        fi
        if [[ -z "${PARTITION_NUMBER}" ]]; then
            echo "Error: PARTITION_NUMBER variable is empty. Exiting..."
            exit 1
        fi
    fi
fi
if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    if [[ -z "${MIRROR_REGISTRY}" ]]; then
        echo "Error: MIRROR_REGISTRY variable is empty. Exiting..."
        exit 1
    fi
    if [[ -z "${MIRROR_REGISTRY_HOSTNAME}" ]]; then
        echo "Error: MIRROR_REGISTRY_HOSTNAME variable is empty. Exiting..."
        exit 1
    fi
    if [[ -z "${MIRROR_REGISTRY_PORT}" ]]; then
        echo "Error: MIRROR_REGISTRY_PORT variable is empty. Exiting..."
        exit 1
    fi
    if [[ -z "${MIRROR_REGISTRY_USERNAME}" ]]; then
        echo "Error: MIRROR_REGISTRY_USERNAME variable is empty. Exiting..."
        exit 1
    fi
    if [[ -z "${MIRROR_REGISTRY_PASSWORD}" ]]; then
        echo "Error: MIRROR_REGISTRY_PASSWORD variable is empty. Exiting..."
        exit 1
    fi
fi

# Check if the file './${CLUSTER_NAME}/orig/install-config.yaml' exists
if [[ ! -f "./${CLUSTER_NAME}/orig/install-config.yaml" ]]; then
    echo "ERROR: The file './${CLUSTER_NAME}/orig/install-config.yaml' does not exist. Exiting..."
    echo "To resolve this issue, execute the following command:"
    echo "sh abi-03-create-file-02-install-config.sh"
    exit 1
fi

# Check if the file './${CLUSTER_NAME}/orig/agent-config.yaml' exists
if [[ ! -f "./${CLUSTER_NAME}/orig/agent-config.yaml" ]]; then
    echo "ERROR: The file './${CLUSTER_NAME}/orig/agent-config.yaml' does not exist. Exiting..."
    echo "To resolve this issue, execute the following command:"
    echo "sh abi-03-create-file-01-agent-config.sh"
    exit 1
fi

# Check if the file './butane' exists
if [[ ! -f "./butane" ]]; then
    echo "ERROR: The file './butane' does not exist. Exiting..."
    echo "To resolve this issue, execute the following command:"
    echo "sh abi-02-install-openshift-tools.sh"
    exit 1
fi

#####################
#####################
#####################

if [[ ! -f "./${CLUSTER_NAME}/orig/openshift" ]]; then
    mkdir -p ./${CLUSTER_NAME}/orig/openshift
fi

butane_ocp_version="$(echo $OCP_VERSION |awk '{print $NF}' |sed 's/\.[0-9]*$/\.0/')"

### Disk partitions are created on OpenShift Container Platform cluster nodes during the Red Hat Enterprise Linux CoreOS (RHCOS) installation.
### After Install:
###   Mounting separate disk for OpenShift 4 container storage
###   https://access.redhat.com/solutions/4952011
### Before Install :
###   Partitioning reference:
###   https://docs.openshift.com/container-platform/4.16/installing/installing_bare_metal/installing-bare-metal.html?extIdCarryOver=true&sc_cid=701f2000001OH6kAAG#installation-user-infra-machines-advanced_disk_installing-bare-metal
if [[ -n "$ADD_DEVICE_NAME" ]]; then
    for role in "master" "worker"; do
        if [[ "PARTITION" = "$ADD_DEVICE_TYPE" ]]; then
cat << EOF > ./${CLUSTER_NAME}/orig/98-${role}-${PARTITION_LABEL}.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 98-${role}-${PARTITION_LABEL}
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  disks:
  - device: ${ADD_DEVICE_NAME} 
    partitions:
    - label: ${PARTITION_LABEL}
      start_mib: ${PARTITION_START_MIB} 
      size_mib: ${PARTITION_SIZE_MIB}
      number: ${PARTITION_NUMBER}
  filesystems:
    - device: /dev/disk/by-partlabel/${PARTITION_LABEL}
      path: ${FILESYSTEM_PATH}
      format: xfs
      mount_options: [defaults, prjquota]
      with_mount_unit: true
EOF
        else
cat << EOF > ./${CLUSTER_NAME}/orig/98-${role}-${PARTITION_LABEL}.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 98-${role}-${PARTITION_LABEL}
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  filesystems:
    - device: ${ADD_DEVICE_NAME}
      path: ${FILESYSTEM_PATH}
      format: xfs
      mount_options: [defaults, prjquota]
      with_mount_unit: true
EOF
        fi        
        ./butane ./${CLUSTER_NAME}/orig/98-${role}-${PARTITION_LABEL}.bu -o ./${CLUSTER_NAME}/orig/openshift/98-${role}-${PARTITION_LABEL}.yaml
    done
fi

### NTP
for role in "master" "worker"; do
cat << EOF > ./${CLUSTER_NAME}/orig/99-${role}-custom-chrony.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-custom-chrony
  labels:
    machineconfiguration.openshift.io/role: ${role}
storage:
  files:
  - path: /etc/chrony.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        pool ${NTP_SERVER_01} iburst
EOF
    if [[ -n $NTP_SERVER_02 ]]; then
cat << EOF >> ./${CLUSTER_NAME}/orig/99-${role}-custom-chrony.bu
        pool ${NTP_SERVER_02} iburst
EOF
    fi
cat << EOF >> ./${CLUSTER_NAME}/orig/99-${role}-custom-chrony.bu
        driftfile /var/lib/chrony/drift
        makestep 1.0 3
        rtcsync
        logdir /var/log/chrony
EOF
    ./butane ./${CLUSTER_NAME}/orig/99-${role}-custom-chrony.bu -o ./${CLUSTER_NAME}/orig/openshift/99-${role}-custom-chrony.yaml
done


### Custom Timezone
###   https://access.redhat.com/solutions/5487331
for role in "master" "worker"; do
cat << EOF > ./${CLUSTER_NAME}/orig/99-${role}-custom-timezone-configuration.bu
variant: openshift
version: $butane_ocp_version
metadata:
  name: 99-${role}-custom-timezone-configuration
  labels:
    machineconfiguration.openshift.io/role: ${role}
systemd:
  units:
  - contents: |
      [Unit]
      Description=set timezone
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=timedatectl set-timezone Asia/Seoul

      [Install]
      WantedBy=multi-user.target
    enabled: true
    name: custom-timezone.service
EOF
    ./butane ./${CLUSTER_NAME}/orig/99-${role}-custom-timezone-configuration.bu -o ./${CLUSTER_NAME}/orig/openshift/99-${role}-custom-timezone-configuration.yaml
done


### Create Objects

### 
### How to change the 'v4InternalSubnet' of OVN-K using Assisted Installer?
### https://access.redhat.com/solutions/7056664

if [[ -n $INTERNAL_MASQUERADE_SUBNET || -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
EOF
    if [[ -n $INTERNAL_MASQUERADE_SUBNET ]]; then
cat << EOF >> ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
      gatewayConfig:
        ipv4:
          internalMasqueradeSubnet: $INTERNAL_MASQUERADE_SUBNET
EOF
    fi
    if [[ -n $INTERNAL_JOIN_SUBNET || -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
cat << EOF >> ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
      ipv4:
EOF
        if [[ -n $INTERNAL_JOIN_SUBNET ]]; then
cat << EOF >> ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
        internalJoinSubnet: $INTERNAL_JOIN_SUBNET
EOF
        fi
        if [[ -n $INTERNAL_TRANSIT_SWITCH_SUBNET ]]; then
cat << EOF >> ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
        internalTransitSwitchSubnet: $INTERNAL_TRANSIT_SWITCH_SUBNET
EOF
        fi
    fi
cat << EOF >> ./${CLUSTER_NAME}/orig/openshift/ovn-kubernetes-config.yaml
    type: OVNKubernetes
EOF
fi

## operator hub off
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/operatorhub_disabled.yaml
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
EOF


### Cluster Samples Operator
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.16/html/images/configuring-samples-operator#configuring-samples-operator
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/config_remove_sample-operator.yaml
apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  architectures:
  - x86_64
  managementState: Removed
EOF


### Automatically allocating resources for nodes
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.16/html/nodes/nodes-nodes-resources-configuring#nodes-nodes-resources-configuring-auto_nodes-nodes-resources-configuring
### https://access.redhat.com/solutions/6988837
for role in "master" "worker"; do
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/${role}-dynamic-node.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: ${role}-dynamic-node
spec:
  autoSizingReserved: true
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${role}: ""
EOF
done


### 1. registry ca trust configmap
### 2. add trusted ca
if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    if [[ "${MIRROR_REGISTRY}" == *:* ]]; then
        MIRROR_REGISTRY_STR="  ${MIRROR_REGISTRY_HOSTNAME}..${MIRROR_REGISTRY_PORT}: |"
    else
        MIRROR_REGISTRY_STR="  ${MIRROR_REGISTRY_HOSTNAME}: |"
    fi
cat << EOF >  ./${CLUSTER_NAME}/orig/openshift/configmap_private-registry-ca.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-registry-ca
  namespace: openshift-config
data:
  updateservice-registry: |
$(xargs -d '\n' -I {} echo "    {}" < "${MIRROR_REGISTRY_TRUST_FILE}")
$(echo "${MIRROR_REGISTRY_STR}")
$(xargs -d '\n' -I {} echo "    {}" < "${MIRROR_REGISTRY_TRUST_FILE}")
EOF

cat << EOF > ./${CLUSTER_NAME}/orig/openshift/image_additional_trusted_ca.yaml
apiVersion: config.openshift.io/v1
kind: Image
metadata:
  name: cluster
spec:
  additionalTrustedCA:
    name: mirror-registry-ca
EOF
fi

### Config mirror registry
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/idms-redhat-operator.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: redhat
spec:
  imageDigestMirrors:
  - mirrors:
    - $MIRROR_REGISTRY
    source: registry.redhat.io
EOF

### Config mirror registry
for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g'); do
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/cs-${catalog}-operator-index.yml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cs-${catalog}-operator
  namespace: openshift-marketplace
spec:
  image: ${MIRROR_REGISTRY}/olm-${catalog}/redhat/${catalog}-operator-index:v${OCP_VERSION%.*}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 20m
EOF
done

### Create MachineConfigPool
for node_role_selector in ${NODE_ROLE_SELECTORS}; do
    node_role=$(          echo ${node_role_selector} |awk -F "--" '{print  $1}' )
    node_name_selector=$( echo ${node_role_selector} |awk -F "--" '{print  $1}' )
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/mcp-${node_role}.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: $node_role
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,${node_role}]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/${node_role}: ""
EOF
done

### Config ingress conroller
cat << EOF > ./${CLUSTER_NAME}/orig/openshift/ingress-controller.yml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  nodePlacement:
    nodeSelector:
      matchLabels:
        ${INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY}: ""
    tolerations:
    - effect: NoSchedule
      operator: Exists
      key: $INGRESS_NODE_SELECTOR_MATCH_LABEL_KEY
EOF
```

```bash

sh abi-03-create-file-03-openshift-configs.sh

```