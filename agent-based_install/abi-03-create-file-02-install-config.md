###
### https://github.com/openshift/installer/blob/master/docs/user/customization.md

```bash

vi abi-03-create-file-02-install-config.sh

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

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "Error: BASE_DOMAIN variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${MACHINE_NETWORK}" ]]; then
    echo "Error: MACHINE_NETWORK variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${SERVICE_NETWORK}" ]]; then
    echo "Error: SERVICE_NETWORK variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${CLUSTER_NETWORK_CIDR}" ]]; then
    echo "Error: CLUSTER_NETWORK_CIDR variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${HOST_PREFIX}" ]]; then
    echo "Error: HOST_PREFIX variable is empty. Exiting..."
    exit 1
fi

if [[ -z "${SSH_KEY_01}" ]]; then
    echo "Error: SSH_KEY_01 variable is empty. Exiting..."
    exit 1
fi

# Check if the file './${CLUSTER_NAME}/orig/agent-config.yaml' exists
if [[ ! -f "./${CLUSTER_NAME}/orig/agent-config.yaml" ]]; then
    echo "ERROR: The file './${CLUSTER_NAME}/orig/agent-config.yaml' does not exist. Exiting..."
    echo "To resolve this issue, execute the following command:"
    echo "sh abi-03-create-file-01-agent-config.sh"
    exit 1
fi

#####################
#####################
#####################

pull_secret=""
if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then
    if [[ -z "${MIRROR_REGISTRY}" ]]; then
        echo "Error: MIRROR_REGISTRY variable is empty. Exiting..."
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
    if [[ -z "${LOCAL_REPOSITORY_NAME}" ]]; then
        echo "Error: LOCAL_REPOSITORY_NAME variable is empty. Exiting..."
        exit 1
    fi

    auth_info="${MIRROR_REGISTRY_USERNAME}:${MIRROR_REGISTRY_PASSWORD}"
    auth_encoding="$(echo -n $auth_info | base64)"
    pull_secret="{\"auths\":{\"${MIRROR_REGISTRY}\":{\"auth\":\"${auth_encoding}\"}}}"
fi

# Initialize counters for master and worker nodes
master_count=$(cat ./${CLUSTER_NAME}/orig/agent-config.yaml |grep "role: master" |wc -l)
worker_count=$(cat ./${CLUSTER_NAME}/orig/agent-config.yaml |grep "role: worker" |wc -l)

### install-config.yaml
cat << EOF  > ./${CLUSTER_NAME}/orig/install-config.yaml
apiVersion: v1
baseDomain: $BASE_DOMAIN
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: $worker_count
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: $master_count
metadata:
  name: $CLUSTER_NAME
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: $MACHINE_NETWORK
  serviceNetwork:
  - $SERVICE_NETWORK
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $HOST_PREFIX
platform:
  none: {}
fips: false
pullSecret: '$pull_secret'
sshKey: |
  $SSH_KEY_01
EOF

if [[ -n $SSH_KEY_02 ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/install-config.yaml
  $SSH_KEY_02
EOF

fi

if [[ -f ${MIRROR_REGISTRY_TRUST_FILE} ]]; then

cat << EOF >> ./${CLUSTER_NAME}/orig/install-config.yaml
additionalTrustBundle: |
$(xargs -d '\n' -I {} echo "  {}" < "${MIRROR_REGISTRY_TRUST_FILE}")
imageDigestSources:
- source: quay.io/openshift-release-dev/ocp-release
  mirrors:
  - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release-images
- source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
  mirrors:
  - ${MIRROR_REGISTRY}/${LOCAL_REPOSITORY_NAME}/release
EOF

fi
```

```bash

sh abi-03-create-file-02-install-config.sh

```