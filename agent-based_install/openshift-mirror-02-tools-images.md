#### Download Tocken

```markdown
https://console.redhat.com/openshift/downloads

  1. Downloads > All categories > Tokens   
  2. Download Pull secret
```


### Create Shell Script : openshift-prepared.sh
```markdown
  - Red Hat OpenShift Container Platform Update Graph. 
      https://access.redhat.com/labs/ocpupgradegraph/update_channel
  - How to prune disconnected image registry using oc mirror.
      https://access.redhat.com/solutions/7011057
```

```bash

podman login registry.redhat.io

```

```bash

if [[ -f ~/Downloads/ocp/pull-secret.txt ]]; then
    cat ~/Downloads/ocp/pull-secret.txt
    cat ~/Downloads/ocp/pull-secret.txt | jq . > $XDG_RUNTIME_DIR/containers/auth.json
    echo ""
fi
cat $XDG_RUNTIME_DIR/containers/auth.json

```

```markdown
이 스크립트는 OpenShift 버전 업데이트와 관련된 작업을 자동화하여 버전 간 의존성과 업데이트 프로세스를 원활하게 관리할 수 있도록 설계되었습니다.
주요 절차는 다음과 같습니다:
0. 초기 설정:
   - 필요한 OpenShift 버전, 경로, 파일명 등을 설정하여 OpenShift 클라이언트, 도구, 이미지 다운로드를 준비합니다.
   - OpenShift 그래프 데이터를 포함한 이미지를 생성하기 위해 Dockerfile을 만듭니다. 이 이미지는 업데이트 프로세스에서 사용됩니다
1. 클라이언트 및 설치 프로그램 다운로드:
   - OCP_UPDATE_PATH에 지정된 각 OpenShift 버전을 반복하여, 클라이언트 및 설치 파일을 특정 버전 폴더에 다운로드합니다.
2. OpenShift 그래프 데이터 이미지 생성
3. eventrouter, support-tools의 이미지 다운로드:
   - podman을 사용하여 eventrouter, support-tools의 이미지를 로컬 태그로 설정하고, 향후 배포를 위해 tar 파일로 저장합니다.
```

```bash

mkdir -p ~/Downloads/ocp/mirror_workspace
cd ~/Downloads/ocp/mirror_workspace

```

```bash

vi openshift-mirror-02-tools-images.sh

```

```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/openshift-mirror-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/openshift-mirror-01-config-preparation.sh"
else
    echo "ERROR: Cannot access '$(dirname "$0")/openshift-mirror-01-config-preparation.sh'. File or directory does not exist. Exiting..."
    exit 1
fi
#####################
### Variable Override Section

#####################
# Define the variable name to check; if not, exit with an error
if [[ -z "${OCP_UPDATE_PATH}" ]]; then
    echo "ERROR: OCP_UPDATE_PATH variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${DOWNLOAD_DIRECTORY}" ]]; then
    echo "ERROR: DOWNLOAD_DIRECTORY variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${EVENTROUTER_IMAGE}" ]]; then
    echo "ERROR: EVENTROUTER_IMAGE variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${SUPPORT_TOOLS_IMAGE}" ]]; then
    echo "ERROR: SUPPORT_TOOLS_IMAGE variable is empty. Exiting..."
    exit 1
fi

# Create the DOWNLOAD_DIRECTORY, and exit if creation fails
if [[ -d "$DOWNLOAD_DIRECTORY" ]]; then
    rm -f localhost_*.tar
    rm -f oc-mirror.*.tar
    rm -f openshift-client-linux-*.tar
    rm -f openshift-install-linux-*.tar
    rm -f butane
else
    mkdir -p "$DOWNLOAD_DIRECTORY" || { echo "Error: Failed to create directory. Exiting..."; exit 1; }
fi

### 1. Downloading OpenShift Client and Installer:
for version in $(echo "$OCP_UPDATE_PATH" | sed 's/--/\n/g' | sort -u); do
    ### oc
    if [[ -n "$OPENSHIFT_CLIENT_RHEL8_FILE" ]]; then
        wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${version}/${OPENSHIFT_CLIENT_RHEL8_FILE}
        mv ${OPENSHIFT_CLIENT_RHEL8_FILE} "${DOWNLOAD_DIRECTORY}/$(echo ${OPENSHIFT_CLIENT_RHEL8_FILE} | awk -F '.' '{print $1}')-v${version}.tar.gz"
    fi
    if [[ -n "$OPENSHIFT_CLIENT_RHEL9_FILE" ]]; then
        wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${version}/${OPENSHIFT_CLIENT_RHEL9_FILE}
        mv ${OPENSHIFT_CLIENT_RHEL9_FILE} "${DOWNLOAD_DIRECTORY}/$(echo ${OPENSHIFT_CLIENT_RHEL9_FILE} | awk -F '.' '{print $1}')-v${version}.tar.gz"
    fi

    ### openshift-install
    if [[ -n "$OPENSHIFT_INSTALL_FILE" ]]; then
        wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${version}/${OPENSHIFT_INSTALL_FILE}
        mv ${OPENSHIFT_INSTALL_FILE} "${DOWNLOAD_DIRECTORY}/$(echo ${OPENSHIFT_INSTALL_FILE} | awk -F '.' '{print $1}')-v${version}.tar.gz"
    fi
    if [[ -n "$OPENSHIFT_INSTALL_RHEL9_FILE" ]]; then
        wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${version}/${OPENSHIFT_INSTALL_RHEL9_FILE}
        mv ${OPENSHIFT_INSTALL_RHEL9_FILE} "${DOWNLOAD_DIRECTORY}/$(echo ${OPENSHIFT_INSTALL_RHEL9_FILE} | awk -F '.' '{print $1}')-v${version}.tar.gz"
    fi
done

### butane
wget https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane
mv butane "${DOWNLOAD_DIRECTORY}/"


if [[ -n "$OC_MIRROR_RHEL8_FILE" ]]; then
    wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/${OC_MIRROR_RHEL8_FILE}
fi
if [[ -n "$OC_MIRROR_RHEL9_FILE" ]]; then
    wget https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/${OC_MIRROR_RHEL9_FILE}
fi

RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)

if [[ -f oc-mirror ]]; then
    rm -f oc-mirror
fi

if [[ "$RHEL_VERSION" == "8" ]]; then
    if [[ -f $OC_MIRROR_RHEL8_FILE ]]; then
        tar xvf ${OC_MIRROR_RHEL8_FILE}
    fi
elif [[ "$RHEL_VERSION" == "9" ]]; then
    if [[ -f $OC_MIRROR_RHEL9_FILE ]]; then
        tar xvf ${OC_MIRROR_RHEL9_FILE}
    fi
fi
mv ${OC_MIRROR_RHEL8_FILE} ${OC_MIRROR_RHEL9_FILE} "${DOWNLOAD_DIRECTORY}/"
if [[ -f oc-mirror ]]; then
    chown $(whoami):$(id -gn) oc-mirror
    chmod ug+x oc-mirror
fi

### 2. OpenShift Grapth Data Image
create_dockerfile

if [[ ! -f ./Dockerfile ]]; then
    echo "ERROR: Cannot access './Dockerfile'. File or directory does not exist. Exiting..."
    exit 1
else
    podman build -t localhost/openshift/graph-data:latest -f ./Dockerfile
    podman save     localhost/openshift/graph-data:latest >  ${DOWNLOAD_DIRECTORY}/localhost_graph-data.tar
fi

### 3. Event Router, Support Tools Images
for image in ${EVENTROUTER_IMAGE} ${SUPPORT_TOOLS_IMAGE}; do
    awk_filter=$(echo $image | awk -F "/" '{print $1}')
    podman pull $image
    podman tag  $image localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}')

    target_name=$(echo $image | awk -F "/" '{print $NF}' | awk -F ":" '{print $1}')

    podman save localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}') > ${DOWNLOAD_DIRECTORY}/localhost_$target_name.tar

    podman rmi  localhost/$(echo $image | awk -F "${awk_filter}/" '{print $2}')
    podman load -i ${DOWNLOAD_DIRECTORY}/localhost_$target_name.tar
done
```

```bash

sh openshift-mirror-02-tools-images.sh

```
