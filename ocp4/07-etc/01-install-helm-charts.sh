###
### Helm 설치
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/building_applications/installing-helm

curl -L https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest/helm-linux-amd64 -o /usr/local/bin/helm

chmod +x /usr/local/bin/helm


###
### 사용자 정의 Helm 차트 리포지터리 구성
### https://docs.redhat.com/ko/documentation/openshift_container_platform/4.19/html/building_applications/configuring-custom-helm-chart-repositories

### https://helm.sh/docs/topics/registries/
### container registry를 Helm 차트 리포지터리로 사용 가능
### Helm 차트를 OCI 형식으로 패키징하고, 푸시하고, 풀 수 있음
### OpenShift Container Platform 클러스터에서 사용자 정의 Helm 차트 리포지터리를 구성할 수 없음. 


### 
### https://chartmuseum.com

CHART_MUSEUM_HOME=/opt/chartmuseum
mkdir -p $CHART_MUSEUM_HOME/charts

podman run --detach \
  --publish 8080:8080 \
  --name charmuseum \
  --restart always \
  -e STORAGE=local \
  -e STORAGE_LOCAL_ROOTDIR=/charts \
  -v ${CHART_MUSEUM_HOME}/charts:/charts:Z \
  ghcr.io/helm/chartmuseum:v0.14.0

# Add SELinux port mappings
semanage port -a -t http_port_t -p tcp 8080

# Configure firewall
firewall-cmd --permanent --add-port=8080/tcp --zone=public
firewall-cmd --reload

### https://docs.sonarsource.com/sonarqube-server/latest/server-installation/on-kubernetes-or-openshift/installing-helm-chart/

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update
helm pull sonarqube/sonarqube

[root@thinkpad helm-charts]# ls -l
total 152
-rw-r--r--. 1 root root 153560 Sep  3 16:59 sonarqube-2025.4.2.tgz





helm repo add chartmuseum http://11.119.120.28:8080

helm repo update

helm push sonarqube chartmuseum



### OCI 사용
helm registry login registry.hub.tistory.disconnected:5000 --insecure
helm push ./sonarqube-2025.4.2.tgz oci://registry.hub.tistory.disconnected:5000/cloudpang-helm-charts --insecure-skip-tls-verify

oc new-project sonarqube 
export MONITORING_PASSCODE="yourPasscode"

helm upgrade --install -n sonarqube sonarqube  oci://registry.hub.tistory.disconnected:5000/cloudpang-helm-charts/sonarqube --insecure-skip-tls-verify \
  --set OpenShift.enabled=true \
  --set postgresql.securityContext.enabled=false \
  --set OpenShift.createSCC=false \
  --set postgresql.containerSecurityContext.enabled=false \
  --set edition=developer \
  --set monitoringPasscode=$MONITORING_PASSCODE


[root@thinkpad helm-charts]# oc get pvc -oyaml
apiVersion: v1
items:
- apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    creationTimestamp: "2025-09-03T22:15:31Z"
    finalizers:
    - kubernetes.io/pvc-protection
    labels:
      app.kubernetes.io/instance: sonarqube
      app.kubernetes.io/name: postgresql
      role: primary
    name: data-sonarqube-postgresql-0
    namespace: sonarqube
    resourceVersion: "309289"
    uid: dfba7823-b5eb-49e8-bcf6-ebeec3cda7c5
  spec:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
    volumeMode: Filesystem
  status:
    phase: Pending
kind: List
metadata:
  resourceVersion: ""