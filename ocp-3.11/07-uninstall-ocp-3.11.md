# OpenShift Container Platform 3.11 클러스터 제거 가이드

이 문서는 Ansible 플레이북과 쉘 스크립트를 사용하여 OpenShift Container Platform (OCP) 3.11 클러스터를 제거하고, 이후 노드의 DNS 설정을 복구하는 단계별 절차를 안내합니다.

## 사전 준비 사항

  - **Ansible 환경**: `openshift-ansible` 플레이북이 설치된 Ansible 환경이 필요합니다.
  - **인벤토리 파일**: `ose-v3.11.784-inventory-hosts`와 같이 정확한 호스트 정보가 포함된 인벤토리 파일이 준비되어 있어야 합니다.
  - **SSH 접근**: 모든 클러스터 노드에 `root` 계정으로 암호 없이 SSH 접속이 가능해야 합니다.
  - **데이터 백업**: **제거 작업은 모든 관련 데이터를 영구적으로 삭제하므로, 실행 전 반드시 중요한 데이터를 백업해야 합니다.**

-----

## 1\. OpenShift 클러스터 제거

`openshift-ansible`에 포함된 공식 제거 플레이북(`uninstall.yml`)을 사용하여 OpenShift를 제거합니다.

### 시나리오 1: 전체 클러스터 제거

전체 클러스터를 한 번에 제거하는 경우, 설치 시 사용했던 인벤토리 파일을 사용합니다.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"
ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/adhoc/uninstall.yml
```

### 시나리오 2: 특정 노드만 제거

클러스터에서 일부 노드만 선택적으로 제거하려면, 제거할 노드만 포함된 별도의 인벤토리 파일을 사용합니다.

**1. 노드 삭제용 인벤토리 파일 생성**

제거할 노드 목록을 포함하는 인벤토리 파일(예: `delete-ose-v3.11.784-hosts`)을 작성합니다.

```ini
[OSEv3:children]
nodes

[OSEv3:vars]
ansible_ssh_user=root
openshift_deployment_type=openshift-enterprise

[nodes]
ifr01.ocp3.cloudpang.lan    openshift_node_group_name="node-config-infra"
ifr02.ocp3.cloudpang.lan    openshift_node_group_name="node-config-router"
```

**2. 노드 제거 플레이북 실행**

위에서 생성한 노드 전용 인벤토리 파일을 사용하여 제거 플레이북을 실행합니다.

```bash
INVENTORY_FILE="delete-ose-v3.11.784-hosts"
ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/adhoc/uninstall.yml
```

---

```bash
CLUSTER_NAME="ocp3"
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

REMOTE_CMD="shutdown -r now"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE all --list-hosts |grep $CLUSTER_NAME); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    echo "COMMAND: $REMOTE_CMD"
    ssh $TARGET_HOSTNAME "bash -c '$REMOTE_CMD'"
    echo ""
done
```

* OpenShift 노드 Healcheck
```bash
vi ping-cluster-nodes.sh
```
```bash
#!/bin/bash

CLUSTER_NAME="ocp3"
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"
TIMEOUT_SECONDS=300 # 5 minutes
PING_INTERVAL_SECONDS=2

mapfile -t hosts < <(ansible -i "$INVENTORY_FILE" all --list-hosts | grep "$CLUSTER_NAME" | awk '{$1=$1};1')
if [ ${#hosts[@]} -eq 0 ]; then
    echo "[ERROR] No hosts found for cluster '$CLUSTER_NAME'. Please check your inventory and cluster name."
    exit 1
fi

online_hosts=()
offline_hosts=()

for host in "${hosts[@]}"; do
    echo "--- Checking host: $host ---"
    start_time=$SECONDS
    is_online=false

    while true; do
        ping_output=$(ping -c 1 -W 5 "$host" 2>&1)
        if [ $? -eq 0 ]; then
            elapsed_time=$((SECONDS - start_time))
            echo "$host is UP! (Responded after ${elapsed_time} seconds)"
            echo "Ping output: $ping_output"
            online_hosts+=("$host")
            is_online=true
            break
        fi
        elapsed_time=$((SECONDS - start_time))
        if (( elapsed_time > TIMEOUT_SECONDS )); then
            echo "$host FAILED to respond after $TIMEOUT_SECONDS seconds."
            echo "Last ping output: $ping_output"
            offline_hosts+=("$host")
            break
        fi
        echo "Pinging $host... Status: Down (waiting $PING_INTERVAL_SECONDS s)"
        sleep $PING_INTERVAL_SECONDS
    done
    echo ""
done

echo "================================================="
echo "### Final Reboot Status Summary"
echo "================================================="
echo ""
echo "Online Hosts (${#online_hosts[@]}):"
if [ ${#online_hosts[@]} -gt 0 ]; then
    printf " - %s\n" "${online_hosts[@]}"
else
    echo " - None"
fi
echo ""
echo "Failed/Offline Hosts (${#offline_hosts[@]}):"
if [ ${#offline_hosts[@]} -gt 0 ]; then
    printf " - %s\n" "${offline_hosts[@]}"
else
    echo " - None"
fi
echo ""
```

```bash
bash ping-cluster-nodes.sh
```

---

## 2\. 클러스터 및 노드 제거 후 DNS 확인 및 DNS 복구 절차

`uninstall.yml` 플레이북은 OpenShift 패키지뿐만 아니라 노드의 `dnsmasq` 설정을 포함한 일부 시스템 설정을 제거합니다. 이로 인해 DNS 이름 해석에 문제가 발생할 수 있으므로, 아래 절차에 따라 각 노드의 상태를 확인하고 DNS 설정을 복원해야 합니다.

### 2.1. 전체 네트워크 상태 확인

제거 작업 후, 각 노드의 기본적인 네트워크 구성(IP, 라우팅, DNS)이 정상적인지 확인합니다.

```bash
CLUSTER_NAME="ocp3"
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE all --list-hosts |grep $CLUSTER_NAME | xargs); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        ### Get the network device used for the default route
        DEVICE=$(ip route get 1.1.1.1 | awk '{print $5}')
        if [ -z "$DEVICE" ]; then
            echo "!!! ERROR: Could not determine the default network device."
            exit 1
        fi

        echo "--- Hostname Information ---"
        echo "hostname               : $(hostname)"
        echo "hostname -f            : $(hostname -f)"
        echo "nmcli general hostname : $(nmcli general hostname)"
        echo ""

        echo "--- Device Network Configuration: $DEVICE ---"
        nmcli con show "$DEVICE" 2>/dev/null | egrep 'ipv4.method:|ipv4.addresses|ipv4.dns:|ipv4.gateway:|ipv6.method:|connection.autoconnect:'
        echo ""

        echo "--- IP Routing Table ---"
        ip r list
        echo ""
        
        echo "--- Contents of /etc/resolv.conf ---"
        cat /etc/resolv.conf
        echo ""

        echo "--- DNS Lookup for Local Hostname ---"
        dig $(hostname)
        echo ""
ENDSSH
done
```

### 2.2. OpenShift DNS 잔여 설정 확인

제거 플레이북이 남긴 OpenShift 관련 DNS 설정 파일이 있는지 확인합니다. 대부분의 파일이 삭제되었을 것입니다.

```bash
CLUSTER_NAME="ocp3"
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE all --list-hosts |grep $CLUSTER_NAME | xargs); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="

    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo "### ls -l /etc/NetworkManager/dispatcher.d/99-origin-dns.sh"
        echo "-------------------------------------------------"
        ls -l /etc/NetworkManager/dispatcher.d/99-origin-dns.sh 2>/dev/null || echo "File not found."
        echo ""
        echo "### ls -l /etc/dnsmasq.d/"
        echo "-------------------------------------------------"
        ls -l /etc/dnsmasq.d/ 2>/dev/null || echo "Directory not found or empty."
        echo ""
        echo "### cat /etc/dnsmasq.d/origin-upstream-dns.conf"
        echo "-------------------------------------------------"
        cat /etc/dnsmasq.d/origin-upstream-dns.conf 2>/dev/null || echo "File not found."
        echo ""
        echo "### cat /etc/resolv.conf"
        echo "-------------------------------------------------"
        cat /etc/resolv.conf
        echo ""
        echo "### DNS Lookup for Local Hostname"
        echo "-------------------------------------------------"
        dig $(hostname)
        echo ""
ENDSSH
done
```

### 2.3. 업스트림 DNS 서버 재구성 (DNS 기능 복원)

`dnsmasq`가 정상적으로 외부 도메인을 조회할 수 있도록 업스트림 DNS 서버 정보를 다시 설정하고 서비스를 재시작합니다.

```bash
CLUSTER_NAME="ocp3"
DNS_SERVER="11.119.120.100"
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE all --list-hosts |grep $CLUSTER_NAME | xargs); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" -- "${DNS_SERVER}"  <<'ENDSSH'
    REMOTE_DNS_SERVER=$1
    
    echo "### Creating new dnsmasq config with upstream DNS: $REMOTE_DNS_SERVER"
    cat <<EOF | sudo tee /etc/dnsmasq.d/upstream-dns.conf > /dev/null
server=$REMOTE_DNS_SERVER
EOF
    
    echo "-------------------------------------------------"
    echo "### Contents of /etc/dnsmasq.d/upstream-dns.conf:"
    cat /etc/dnsmasq.d/upstream-dns.conf
    echo ""

    echo "### Restarting dnsmasq service..."
    sudo systemctl restart dnsmasq.service
    echo "-------------------------------------------------"
    echo "Restart complete."
    echo ""

    echo "### Verifying DNS lookup for hostname..."
    echo "-------------------------------------------------"
    dig $(hostname)
    echo ""
ENDSSH
done
```