
## Private Registry에 이미지 등록

### OpenShift 설치 이미지 등록


```bash

vi bastion-01-config-preparation.sh

```

```bash
#!/bin/bash

#OCP_UPDATE_PATH="4.13.37"
#OCP_UPDATE_PATH="4.13.37--4.15.35"
#OCP_UPDATE_PATH="4.13.37--4.15.35--eus-4.16.16"
#OCP_UPDATE_PATH="4.16.7"
OCP_UPDATE_PATH="4.17.9--4.17.10"

OCP_TARGET_VERSION="4.17.9"

DOWNLOAD_DIRECTORY="ocp4-install-files-v${OCP_UPDATE_PATH}"

OPENSHIFT_CLIENT_RHEL8_FILE="openshift-client-linux-amd64-rhel8"
OPENSHIFT_CLIENT_RHEL9_FILE="openshift-client-linux-amd64-rhel9"

OC_MIRROR_RHEL8_FILE="oc-mirror.tar.gz"
OC_MIRROR_RHEL9_FILE="oc-mirror.rhel9.tar.gz"

# Default paths: /usr/local/bin for root, $HOME/bin for other users
OCP_TOOLS_DIR=""

MIRROR_REGISTRY="nexus.cloudpang.tistory.disconnected:5000"
USERNAME="admin"
PASSWORD="redhat1!"
```