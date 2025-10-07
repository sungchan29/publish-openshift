### Create user
### Binds a given role to specified users for all projects in the cluster.

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE masters --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo "cat /etc/origin/master/master-config.yaml |grep htpasswd"
        echo "--------------------------------------------------------"
        cat /etc/origin/master/master-config.yaml |grep htpasswd
        echo ""
ENDSSH
done
```
* ocpadmin 사용자 추가
```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE masters --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
    echo "htpasswd -b /etc/origin/master/htpasswd ocpadmin redhat"
    echo "-------------------------------------------------------"
    htpasswd -b /etc/origin/master/htpasswd ocpadmin redhat
    sleep 1
    echo ""
    echo "cat /etc/origin/master/htpasswd"
    echo "-------------------------------"
    cat /etc/origin/master/htpasswd
    echo ""
ENDSSH
done
```
* admin 사용자 추가
```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE masters --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
    echo "htpasswd -b /etc/origin/master/htpasswd ocpadmin redhat"
    echo "-------------------------------------------------------"
    htpasswd -b /etc/origin/master/htpasswd admin redhat
    sleep 1
    echo ""
    echo "cat /etc/origin/master/htpasswd"
    echo "-------------------------------"
    cat /etc/origin/master/htpasswd
    echo ""
ENDSSH
done
```
* admin 사용자 비밀번호 변경
```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE masters --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
    echo "htpasswd -b /etc/origin/master/htpasswd ocpadmin redhat"
    echo "-------------------------------------------------------"
    htpasswd -b /etc/origin/master/htpasswd admin redhat.!
    sleep 1
    echo ""
    echo "cat /etc/origin/master/htpasswd"
    echo "-------------------------------"
    cat /etc/origin/master/htpasswd
    echo ""
ENDSSH
done
```
* ocpadmin 계정에 cluster-admin 권한 부여
```bash
ssh mst01.ocp3.cloudpang.lan

oc adm policy add-cluster-role-to-user cluster-admin ocpadmin

exit
```

```bash
oc login -u ocpadmin https://csmaster.ocp3.cloudpang.lan:8443
```

* NFS 서버에서 디렉터리 생성 및 권한 설정
```bash
mkdir -p /data/exports/ocp3/monitoring/prometheus-storage-00
mkdir -p /data/exports/ocp3/monitoring/prometheus-storage-01
mkdir -p /data/exports/ocp3/monitoring/alert-storage-00
mkdir -p /data/exports/ocp3/monitoring/alert-storage-01
mkdir -p /data/exports/ocp3/monitoring/alert-storage-02
chmod -R 777 /data/exports/ocp3/monitoring

mkdir -p /data/exports/ocp3/docker-registry
chmod -R 777 /data/exports/ocp3/docker-registry
```

```bash
oc create -f - <<API
apiVersion: "v1"
kind: "PersistentVolume"
metadata:
  name: "prometheus-volume-00"
spec:
  capacity:
    storage: "50Gi"
  accessModes:
    - "ReadWriteOnce"
  nfs:
    path: /data/exports/ocp3/monitoring/prometheus-storage-00
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API

oc create -f - <<API
apiVersion: "v1"
kind: "PersistentVolume"
metadata:
  name: "prometheus-volume-01"
spec:
  capacity:
    storage: "50Gi"
  accessModes:
    - "ReadWriteOnce"
  nfs:
    path: /data/exports/ocp3/monitoring/prometheus-storage-01
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API

oc create -f - <<API
apiVersion: "v1"
kind: "PersistentVolume"
metadata:
  name: "alertmanager-volume-00"
spec:
  capacity:
    storage: "2Gi"
  accessModes:
    - "ReadWriteOnce"
  nfs:
    path: /data/exports/ocp3/monitoring/alert-storage-00
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API

oc create -f - <<API
apiVersion: "v1"
kind: "PersistentVolume"
metadata:
  name: "alertmanager-volume-01"
spec:
  capacity:
    storage: "2Gi"
  accessModes:
    - "ReadWriteOnce"
  nfs:
    path: /data/exports/ocp3/monitoring/alert-storage-01
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API

oc create -f - <<API
apiVersion: "v1"
kind: "PersistentVolume"
metadata:
  name: "alertmanager-volume-02"
spec:
  capacity:
    storage: "2Gi"
  accessModes:
    - "ReadWriteOnce"
  nfs:
    path: /data/exports/ocp3/monitoring/alert-storage-02
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API
```


```bash
oc project default

oc adm policy add-scc-to-user hostnetwork -z lab1-router

oc adm router lab1-router \
--replicas=1 \
--stats-user='admin' \
--stats-password='redhat' \
--stats-port='1936' \
--service-account='lab1-router' \
--ports='80:80,443:443' \
--selector='node-role.kubernetes.io/infra=true' \
--images='bst01.ocp3.cloudpang.lan:5000/openshift3/ose-${component}:${version}'

oc adm policy add-cluster-role-to-user cluster-reader system:serviceaccount:default:lab1-router
```

* Setting up the Registry
```bash
oc project default

oc adm registry \
  --config=/etc/origin/master/admin.kubeconfig \
  --service-account=registry \
  --images='bst01.ocp3.cloudpang.lan:5000/openshift3/ose-${component}:${version}' \
  --selector='node-role.kubernetes.io/infra=true'

oc create -f - <<API
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfspv-docker-registry
  labels:
    volume-type: nfs
    availability-zone: docker-registry
spec:
  capacity:
    storage: 10Gi
  accessModes:
  - ReadWriteMany
  nfs:
    path: /data/exports/ocp3/docker-registry
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain
API

oc create -f - <<API
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfspvc-docker-registry
  namespace: default
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  selector:
    matchLabels:
      volume-type: nfs
      availability-zone: docker-registry
API

oc set volume deploymentconfigs/docker-registry --add --name=registry-storage -t pvc --claim-name=nfspvc-docker-registry --overwrite
```


### Issues resolving docker-registry.default.svc
* https://access.redhat.com/solutions/3498011

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo "### echo 'server=/svc/' > /etc/dnsmasq.d/bandomain.conf && systemctl restart dnsmasq"
        echo "------------------------------------------------------------------------------------"
        echo 'server=/svc/' > /etc/dnsmasq.d/bandomain.conf && systemctl restart dnsmasq
        echo ""
ENDSSH
done
```

```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"

for TARGET_HOSTNAME in $(ansible -i $INVENTORY_FILE nodes --list-hosts |grep -v " hosts "); do
    echo "================================================="
    echo "  Processing Hostname: $TARGET_HOSTNAME"
    echo "================================================="
    ssh -o StrictHostKeyChecking=no ${TARGET_HOSTNAME} "bash -s" <<'ENDSSH'
        echo "### cat /etc/resolv.conf"
        echo "------------------------"
        cat /etc/resolv.conf
        echo ""
        echo "### cat /etc/dnsmasq.d/bandomain.conf"
        echo "-------------------------------------"
        cat /etc/dnsmasq.d/bandomain.conf
        echo ""
        echo "### nslookup docker-registry.default.svc"
        echo "------------------------------------------------"
        nslookup docker-registry.default.svc
        echo ""
ENDSSH
done
```


```bash
INVENTORY_FILE="ose-v3.11.784-inventory-hosts"
ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/metrics-server/config.yml -e openshift_metrics_server_install=true
```

```log
oc logs metrics-server-69996495f8-tpx5j -n openshift-metrics-server
...
I1006 13:42:44.217054       1 logs.go:41] http: TLS handshake error from 172.33.4.1:51810: remote error: tls: bad certificate
I1006 13:42:44.227469       1 logs.go:41] http: TLS handshake error from 172.33.4.1:51812: remote error: tls: bad certificate
...
```

https://access.redhat.com/solutions/5307341

```bash
oc delete secret metrics-server-certs -n openshift-metrics-server

INVENTORY_FILE="ose-v3.11.784-inventory-hosts"
ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/metrics-server/config.yml -e openshift_metrics_server_install=false

ansible-playbook -i $INVENTORY_FILE /usr/share/ansible/openshift-ansible/playbooks/metrics-server/config.yml -e openshift_metrics_server_install=true
```

```bash
oc adm top node
```

```log
[root@bst01 workspace]# oc adm top node
NAME                       CPU(cores)   CPU%      MEMORY(bytes)   MEMORY%
ifr01.ocp3.cloudpang.lan   151m         1%        1469Mi          19%
ifr02.ocp3.cloudpang.lan   149m         1%        1529Mi          19%
mst01.ocp3.cloudpang.lan   204m         2%        1902Mi          24%
mst02.ocp3.cloudpang.lan   238m         2%        1864Mi          24%
mst03.ocp3.cloudpang.lan   363m         4%        2050Mi          26%
```