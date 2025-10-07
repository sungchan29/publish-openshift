# OpenShift 3.11 신규 노드 추가 절차

이 문서는 기존에 구성된 OpenShift Container Platform 3.11 클러스터에 새로운 RHEL 7.8 서버를 노드로 추가하는 전체 과정을 설명합니다. 모든 작업은 Bastion 호스트에서 Ansible 인벤토리 파일과 셸 스크립트를 사용하여 신규 노드에 원격으로 실행하는 것을 기준으로 합니다.

-----

## 1\. 사전 준비: Ansible 인벤토리 수정

먼저 Ansible 인벤토리 파일을 수정하여 추가할 노드를 정의합니다. `[OSEv3:children]` 섹션에 `new_nodes` 그룹을 추가하여 Ansible이 새로운 노드 그룹을 인식하도록 합니다.

```ini
[OSEv3:children]
masters
nodes
etcd
new_nodes
```

파일 하단에 `[new_nodes]` 그룹을 새로 만들고, 추가할 호스트의 정보와 역할을 지정합니다. 작업이 완료되면 이 호스트는 `[nodes]` 그룹으로 이동될 것입니다.

```ini
[nodes]
mst01.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
mst02.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
mst03.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
ifr01.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
ifr02.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"

[new_nodes]
ifr03.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
```

-----

## 2\. 신규 노드 준비 (Node Preparation)

RHEL 7.8이 최소 설치된 신규 노드에 접속하여 OpenShift 설치를 위한 사전 작업을 수행합니다. 아래 스크립트들은 `new_nodes` 그룹에 포함된 모든 호스트를 대상으로 실행됩니다.

### SSH 공개키 배포

Ansible 및 셸 스크립트가 비밀번호 없이 원격 노드에 접속할 수 있도록 Bastion 호스트의 SSH 공개키를 신규 노드에 복사합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "[INFO] Checking for existing SSH key on $TARGET_HOSTNAME..."
    if ! ssh -o PasswordAuthentication=no -o ConnectTimeout=5 ${TARGET_HOSTNAME} exit 2>/dev/null; then
        echo "[ACTION] SSH key not found or password login is required."

        read -p "[CONFIRM] Do you want to copy the SSH key to $TARGET_IP? (y/N): " -r REPLY < /dev/tty
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "[ACTION] User confirmed. Attempting to copy key..."
            ssh-copy-id -o ConnectTimeout=10 ${REMOTE_USER}@${TARGET_IP}
            if [ $? -eq 0 ]; then
                echo "[INFO] SSH key copied successfully to $TARGET_IP."
            else
                echo "[ERROR] Failed to copy SSH key to $TARGET_IP. Skipping this host."
                continue
            fi
        else
            echo "[INFO] User declined. Skipping all actions for $TARGET_IP."
            continue
        fi
    else
        echo "[INFO] SSH key already exists."
    fi
    echo ""
done
```

### Yum Repository 설정 및 OS 업데이트

Bastion 호스트의 Yum 리포지토리 설정 파일을 신규 노드에 복사합니다.

```bash
SOURCE_FILE="/etc/yum.repos.d/redhat.repo"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    scp  $SOURCE_FILE $TARGET_HOSTNAME:$SOURCE_FILE
    echo ""
done
```

신규 노드에서 `yum update`를 백그라운드로 실행하여 OS를 최신 상태로 업데이트합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -f $TARGET_HOSTNAME "nohup yum clean all && yum repolist && yum update -y > /tmp/yum_update.log 2>&1 &"
    echo ""
done
```

백그라운드에서 진행 중인 `yum update` 작업의 상태를 확인합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh $TARGET_HOSTNAME "
        if pgrep -f 'yum update' > /dev/null; then
            echo 'Status: In Progress... (yum process is running)'
            echo '--- Last 5 lines of log ---'
            tail -n 5 /tmp/yum_update.log
        else
            if grep -q 'Complete!' /tmp/yum_update.log; then
                echo 'Status: Success'
            elif grep -q 'Error:' /tmp/yum_update.log; then
                echo 'Status: Failed (Errors found in log)'
            else
                echo 'Status: Unknown (Process finished, but \"Complete!\" not found)'
            fi
        fi
    echo ''
  "
done
```

### 시스템 재부팅 및 Health Check

OS 업데이트(커널 업데이트 등)를 완전히 적용하기 위해 신규 노드를 재부팅합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh $TARGET_HOSTNAME "shutdown -r now"
    echo ""
done
```

재부팅된 노드가 정상적으로 응답하는지 `ping` 테스트를 통해 확인합니다.

```bash
bash scripts/ping-cluster-nodes.sh new_nodes
```

### 필수 패키지 설치 및 시간 동기화

OpenShift 설치에 필요한 기본 유틸리티 패키지들을 설치합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "ssh $TARGET_HOSTNAME \"nohup yum install -y wget git net-tools bind-utils yum-utils bridge-utils bash-completion kexec-tools sos psacct chrony > /tmp/yum_update.log 2>&1 &\""
    ssh -f $TARGET_HOSTNAME "nohup yum install -y wget git net-tools bind-utils yum-utils bridge-utils bash-completion kexec-tools sos psacct chrony > /tmp/yum_update.log 2>&1 &"
    echo ""
done
```

패키지 설치 작업의 진행 상태를 확인합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh $TARGET_HOSTNAME "
        if pgrep -f 'yum update' > /dev/null; then
            echo 'Status: In Progress... (yum process is running)'
            echo '--- Last 5 lines of log ---'
            tail -n 5 /tmp/yum_update.log
        else
            if grep -q 'Complete!' /tmp/yum_update.log; then
                echo 'Status: Success'
            elif grep -q 'Error:' /tmp/yum_update.log; then
                echo 'Status: Failed (Errors found in log)'
            else
                echo 'Status: Unknown (Process finished, but \"Complete!\" not found)'
            fi
        fi
    echo ''
  "
done
```

시간 동기화를 위해 Bastion 호스트의 `chrony.conf` 파일을 신규 노드에 배포합니다.

```bash
SOURCE_FILE="/etc/chrony.conf"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    scp $SOURCE_FILE $TARGET_HOSTNAME:$SOURCE_FILE
    ssh $TARGET_HOSTNAME "cat $SOURCE_FILE  |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$"
    echo ""
done
```

신규 노드에서 `chronyd` 서비스를 활성화하고 시작합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh $TARGET_HOSTNAME "systemctl enable chronyd.service && systemctl restart chronyd.service && systemctl status chronyd.service"
    echo ""
done
```

시간 동기화 상태를 최종적으로 확인합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh $TARGET_HOSTNAME "chronyc sources && echo '' && chronyc sourcestats && echo '' && date"
    echo ""
done
```

### 네트워크 설정 확인

신규 노드의 호스트 이름, IP, DNS, 라우팅 테이블 등 주요 네트워크 설정이 올바르게 구성되었는지 점검합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -t "$TARGET_HOSTNAME" <<'ENDSSH'
        DEVICE=$(ip route get 1.1.1.1 | awk '{print $5}')
        if [ -z "$DEVICE" ]; then
            echo "!!! ERROR: Could not determine the primary network device."
            exit 1
        fi
        echo "--- Hostname Information ---"
        hostname
        hostname -f
        nmcli general hostname
        echo ""
        echo "--- Network Configuration for device: $DEVICE ---"
        nmcli con show "$DEVICE" | egrep 'ipv4.addresses|ipv4.dns:|ipv4.gateway:'
        echo ""
        echo "--- IP Route List ---"
        ip r list
        echo ""
        echo "--- cat /etc/resolv.conf ---"
        cat /etc/resolv.conf
        echo ""
ENDSSH
done
```

-----

## 3\. Docker 설치 및 설정

### Docker 패키지 설치

Yum 캐시를 정리하고 `docker` 패키지를 설치합니다.

```bash
REMOTE_CMD="yum clean all && yum repolist"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

```bash
REMOTE_CMD="nohup yum install -y docker > /tmp/yum_update.log 2>&1 &"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh -f $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

`docker` 설치 로그를 확인하여 작업이 잘 완료되었는지 확인합니다.

```bash
REMOTE_CMD="cat /tmp/yum_update.log"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

### Docker 스토리지 설정

Docker 컨테이너 이미지를 저장할 두 번째 디스크(`DISK2`)를 확인합니다.

```bash
REMOTE_CMD="fdisk -l && echo \"\" && blkid && echo  \"\" && lsblk"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

두 번째 디스크(`/dev/vdb`)를 Docker 전용 스토리지로 사용하도록 `docker-storage-setup`을 실행하고 Docker 서비스를 시작합니다. 이 스크립트는 원격 노드에서 LVM을 구성하여 `/var/lib/docker`를 마운트합니다.

```bash
TARGET_DISK="/dev/vdb"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "--- Starting full Docker setup on [${TARGET_HOSTNAME}] for disk [${TARGET_DISK}] ---"

    ### Connect via SSH, execute 'bash -s' and pass the TARGET_DISK variable as an argument.
    ### The remote script will receive TARGET_DISK as its first argument ($1).
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" -- "${TARGET_DISK}" <<'ENDSSH'
    ### Assign the first argument ($1) to a variable on the remote server for readability.
    REMOTE_DISK=$1

    echo "### Step 1: Configuring Docker storage..."
    cat <<EOF > /etc/sysconfig/docker-storage-setup
STORAGE_DRIVER=overlay2
DEVS=${REMOTE_DISK}
VG=docker-vg
CONTAINER_ROOT_LV_NAME=docker
CONTAINER_ROOT_LV_SIZE=100%FREE
CONTAINER_ROOT_LV_MOUNT_PATH=/var/lib/docker
EOF
    echo "### Step 2: Running docker-storage-setup..."
    docker-storage-setup

    echo ""
    echo "### Step 3: Starting and enabling the Docker service..."
    systemctl start docker
    systemctl enable docker

    echo ""
    echo "### Step 4: Checking Docker service status..."
    ### Use --no-pager to prevent the output from blocking the script.
    systemctl status docker --no-pager

    echo ""
    echo "### Step 5: Displaying Docker info to verify storage driver..." 
    docker info
ENDSSH
    ### Check the final exit status of the entire remote SSH command block.
    if [ $? -eq 0 ]; then
        echo "--- [${TARGET_HOSTNAME}] setup SUCCEEDED ---"
    else
        echo "--- [${TARGET_HOSTNAME}] setup FAILED ---"
    fi
    echo ""
done
```

### 최종 확인 및 재부팅

Docker 스토리지 설정 후 디스크 상태를 다시 확인합니다.

```bash
REMOTE_CMD="fdisk -l && echo \"\" && blkid && echo  \"\" && lsblk"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

모든 설정을 적용하기 위해 노드를 재부팅합니다.

```bash
REMOTE_CMD="shutdown -r now"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

재부팅 후 노드 상태와 Docker 스토리지 설정을 최종적으로 확인합니다.

```bash
bash scripts/ping-cluster-nodes.sh new_nodes
```

```bash
REMOTE_CMD="fdisk -l && echo \"\" && blkid && echo  \"\" && lsblk"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

```bash
REMOTE_CMD="docker info"

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

-----

## 4\. 클러스터에 신규 노드 추가

준비가 완료된 노드를 Ansible 플레이북을 사용하여 OpenShift 클러스터에 추가합니다.

먼저 `openshift_node_group.yml` 플레이북을 실행하여 새 노드 그룹을 위한 ConfigMap을 클러스터에 생성합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/openshift-master/openshift_node_group.yml
```

`scaleup.yml` 플레이북을 실행하여 신규 노드를 클러스터에 최종적으로 추가하고 프로비저닝합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/openshift-node/scaleup.yml
```

-----

## 5\. 추가 노드 설정 확인

클러스터에 노드가 추가된 후, Ansible에 의해 신규 노드의 Docker 및 컨테이너 레지스트리 설정이 올바르게 변경되었는지 확인합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE new_nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo ""
        echo "### cat /etc/sysconfig/docker |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$"
        echo "-----------------------------------------------------------------------------"
        cat /etc/sysconfig/docker |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$
        echo ""
        echo "### cat /etc/containers/registries.conf |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$"
        echo "---------------------------------------------------------------------------------------"
        cat /etc/containers/registries.conf |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$
        echo ""
        echo "### ps -ef |grep docker |grep insecure"
        echo "--------------------------------------"
        ps -ef |grep docker |grep insecure
        echo ""
ENDSSH
done
```

-----

## 6\. 마무리: Ansible 인벤토리 정리

노드 추가 작업이 성공적으로 완료되면, 인벤토리 파일을 정리하여 현재 클러스터 상태를 정확하게 반영합니다.

먼저 `[OSEv3:children]` 섹션에서 `new_nodes` 그룹을 삭제합니다.

```ini
[OSEv3:children]
masters
nodes
etcd
```

추가된 노드를 `[nodes]` 그룹으로 이동하고, `[new_nodes]` 그룹은 삭제하거나 주석 처리합니다.

```ini
[nodes]
mst01.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
mst02.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
mst03.ocp3.cloudpang.lan    openshift_node_group_name="node-config-master"
ifr01.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
ifr02.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
ifr03.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
```

인벤토리 파일 수정 후, **전체 노드**를 대상으로 설정을 다시 한번 확인하여 클러스터의 일관성을 검증합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo ""
        echo "### cat /etc/sysconfig/docker |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$"
        echo "-----------------------------------------------------------------------------"
        cat /etc/sysconfig/docker |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$
        echo ""
        echo "### cat /etc/containers/registries.conf |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$"
        echo "---------------------------------------------------------------------------------------"
        cat /etc/containers/registries.conf |grep -v ^[[:blank:]]*# |grep -v ^[[:blank:]]*$
        echo ""
        echo "### ps -ef |grep docker |grep insecure"
        echo "--------------------------------------"
        ps -ef |grep docker |grep insecure
        echo ""
ENDSSH
done
```