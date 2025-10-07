# OpenShift 3.11 오프라인 설치를 위한 패키지 및 이미지 준비

이 문서는 인터넷이 연결된 RHEL 7.x 서버(Bastion/Helper 노드)를 사용하여, 오프라인 환경에 OpenShift Container Platform 3.11을 설치하는 데 필요한 모든 RPM 패키지와 컨테이너 이미지를 준비하는 단계별 가이드를 제공합니다.

## 사전 준비 사항

  - 인터넷에 연결 가능하고 Red Hat 서브스크립션이 등록된 **RHEL 7.x 서버** 1대
  - 유효한 **Red Hat 계정** 및 OpenShift 3.11 설치를 위한 **Pool ID**
  - RPM 리포지토리와 컨테이너 이미지를 저장할 충분한 디스크 공간 (최소 100GB 이상 권장)
  - `docker` 서비스가 설치되어 있고 실행 중인 상태

-----

## 1단계: RPM 패키지 리포지토리 미러링

OpenShift 설치 및 운영에 필요한 모든 RPM 패키지를 다운로드하여 로컬 Yum 리포지토리를 생성합니다.

### 1.1. Red Hat 계정 등록 및 서브스크립션 연결

서버를 Red Hat에 등록하고 구매한 서브스크립션 Pool에 연결합니다.

```bash
# Red Hat 계정으로 시스템 등록
subscription-manager register --username=[your-redhat-account]

# 사용 가능한 서브스크립션 Pool ID 확인
subscription-manager list --available | more

# 확인된 Pool ID로 서브스크립션 연결
subscription-manager attach --pool=[your-pool-id]
```

### 1.2. 필요한 리포지토리 활성화

모든 리포지토리를 비활성화한 후, OpenShift 3.11 설치에 필요한 RHEL 7 및 Ansible 리포지토리만 선택적으로 활성화합니다.

```bash
# 모든 리포지토리 비활성화
subscription-manager repos --disable="*"

# OpenShift 3.11 및 Ansible 2.9 관련 리포지토리 활성화
subscription-manager repos \
  --enable="rhel-7-server-rpms" \
  --enable="rhel-7-server-extras-rpms" \
  --enable="rhel-7-server-ose-3.11-rpms" \
  --enable="rhel-7-server-ansible-2.9-rpms"

# 활성화된 리포지토리 목록 확인
subscription-manager repos --list-enabled
```

### 1.3. 리포지토리 동기화 도구 설치

Yum 리포지토리를 다운로드하고 생성하는 데 필요한 유틸리티를 설치합니다.

```bash
yum -y install yum-utils createrepo docker git
```

### 1.4. 리포지토리 동기화 실행

활성화된 리포지토리의 모든 RPM 패키지를 로컬 디렉터리로 다운로드(`reposync`)한 후, 해당 디렉터리를 Yum 리포지토리로 만듭니다(`createrepo`).

```bash
# 패키지를 저장할 디렉터리 생성
mkdir -p /var/repos/lmn

# 각 리포지토리를 순회하며 동기화 실행
for repo in \
rhel-7-server-rpms \
rhel-7-server-extras-rpms \
rhel-7-server-ansible-2.9-rpms \
rhel-7-server-ose-3.11-rpms
do
    echo "--- Syncing repo: ${repo} ---"
    reposync --gpgcheck -lmn --repoid=${repo} --download_path=/var/repos/lmn
    createrepo -v /var/repos/lmn/${repo}
done

echo "--- RPM repository mirroring complete. ---"
```

> **결과물**: `/var/repos/lmn` 디렉터리에 4개의 리포지토리별 RPM 패키지와 메타데이터가 생성됩니다. 이 디렉터리를 오프라인 환경으로 복사하여 웹 서버 등을 통해 Yum 리포지토리로 제공해야 합니다.

-----

## 2단계: 컨테이너 이미지 다운로드 및 저장

OpenShift 3.11을 구성하는 모든 컨테이너 이미지를 다운로드하여 오프라인 환경으로 이동할 수 있도록 `.tar` 파일로 저장합니다.

### 2.1. Red Hat 컨테이너 레지스트리 로그인

`docker login` 명령을 사용하여 Red Hat 계정으로 레지스트리에 인증합니다.

```bash
docker login registry.redhat.io
```

### 2.2. OCP 컨테이너 이미지 Pull

설치에 필요한 모든 컨테이너 이미지를 로컬 Docker 데몬으로 다운로드합니다. 이미지 목록을 변수로 관리하여 재사용성을 높입니다.
이 단계에서는 버전 호환성을 보장하기 위해, 앞서 1단계에서 미러링한 Yum 리포지토리의 openshift-ansible RPM 패키지 버전을 확인하여 컨테이너 이미지 태그(OSE_TAG)로 사용합니다.

```bash
find /var/repos/lmn -name 'openshift-ansible-3*.rpm' | head -n 1
```

```bash
OSE_TAG="v3.11.784"

### 필수 이미지 목록 정의
OSE_IMAGES=(
    "openshift3/apb-base:$OSE_TAG"
    "openshift3/apb-tools:$OSE_TAG"
    "openshift3/automation-broker-apb:$OSE_TAG"
    "openshift3/csi-attacher:$OSE_TAG"
    "openshift3/csi-driver-registrar:$OSE_TAG"
    "openshift3/csi-livenessprobe:$OSE_TAG"
    "openshift3/csi-provisioner:$OSE_TAG"
    "openshift3/grafana:$OSE_TAG"
    "openshift3/kuryr-controller:$OSE_TAG"
    "openshift3/kuryr-cni:$OSE_TAG"
    "openshift3/local-storage-provisioner:$OSE_TAG"
    "openshift3/manila-provisioner:$OSE_TAG"
    "openshift3/mariadb-apb:$OSE_TAG"
    "openshift3/mediawiki:$OSE_TAG"
    "openshift3/mediawiki-apb:$OSE_TAG"
    "openshift3/mysql-apb:$OSE_TAG"
    "openshift3/ose-ansible-service-broker:$OSE_TAG"
    "openshift3/ose-cli:$OSE_TAG"
    "openshift3/ose-cluster-autoscaler:$OSE_TAG"
    "openshift3/ose-cluster-capacity:$OSE_TAG"
    "openshift3/ose-cluster-monitoring-operator:$OSE_TAG"
    "openshift3/ose-console:$OSE_TAG"
    "openshift3/ose-configmap-reloader:$OSE_TAG"
    "openshift3/ose-control-plane:$OSE_TAG"
    "openshift3/ose-deployer:$OSE_TAG"
    "openshift3/ose-descheduler:$OSE_TAG"
    "openshift3/ose-docker-builder:$OSE_TAG"
    "openshift3/ose-docker-registry:$OSE_TAG"
    "openshift3/ose-efs-provisioner:$OSE_TAG"
    "openshift3/ose-egress-dns-proxy:$OSE_TAG"
    "openshift3/ose-egress-http-proxy:$OSE_TAG"
    "openshift3/ose-egress-router:$OSE_TAG"
    "openshift3/ose-haproxy-router:$OSE_TAG"
    "openshift3/ose-hyperkube:$OSE_TAG"
    "openshift3/ose-hypershift:$OSE_TAG"
    "openshift3/ose-keepalived-ipfailover:$OSE_TAG"
    "openshift3/ose-kube-rbac-proxy:$OSE_TAG"
    "openshift3/ose-kube-state-metrics:$OSE_TAG"
    "openshift3/ose-metrics-server:$OSE_TAG"
    "openshift3/ose-node:$OSE_TAG"
    "openshift3/ose-node-problem-detector:$OSE_TAG"
    "openshift3/ose-operator-lifecycle-manager:$OSE_TAG"
    "openshift3/ose-ovn-kubernetes:$OSE_TAG"
    "openshift3/ose-pod:$OSE_TAG"
    "openshift3/ose-prometheus-config-reloader:$OSE_TAG"
    "openshift3/ose-prometheus-operator:$OSE_TAG"
    "openshift3/ose-recycler:$OSE_TAG"
    "openshift3/ose-service-catalog:$OSE_TAG"
    "openshift3/ose-template-service-broker:$OSE_TAG"
    "openshift3/ose-tests:$OSE_TAG"
    "openshift3/ose-web-console:$OSE_TAG"
    "openshift3/postgresql-apb:$OSE_TAG"
    "openshift3/registry-console:$OSE_TAG"
    "openshift3/snapshot-controller:$OSE_TAG"
    "openshift3/snapshot-provisioner:$OSE_TAG"
    "rhel7/etcd:3.2.28"
)

### 선택(Optional) 이미지 목록 정의 (Metrics, Logging, GlusterFS 등)
OPTIONAL_IMAGES=(
    "openshift3/metrics-cassandra:$OSE_TAG"
    "openshift3/metrics-hawkular-metrics:$OSE_TAG"
    "openshift3/metrics-hawkular-openshift-agent:$OSE_TAG"
    "openshift3/metrics-heapster:$OSE_TAG"
    "openshift3/metrics-schema-installer:$OSE_TAG"
    "openshift3/oauth-proxy:$OSE_TAG"
    "openshift3/ose-logging-curator5:$OSE_TAG"
    "openshift3/ose-logging-elasticsearch5:$OSE_TAG"
    "openshift3/ose-logging-eventrouter:$OSE_TAG"
    "openshift3/ose-logging-fluentd:$OSE_TAG"
    "openshift3/ose-logging-kibana5:$OSE_TAG"
    "openshift3/prometheus:$OSE_TAG"
    "openshift3/prometheus-alertmanager:$OSE_TAG"
    "openshift3/prometheus-node-exporter:$OSE_TAG"
    "cloudforms46/cfme-openshift-postgresql"
    "cloudforms46/cfme-openshift-memcached"
    "cloudforms46/cfme-openshift-app-ui"
    "cloudforms46/cfme-openshift-app"
    "cloudforms46/cfme-openshift-embedded-ansible"
    "cloudforms46/cfme-openshift-httpd"
    "cloudforms46/cfme-httpd-configmap-generator"
    "rhgs3/rhgs-server-rhel7"
    "rhgs3/rhgs-volmanager-rhel7"
    "rhgs3/rhgs-gluster-block-prov-rhel7"
    "rhgs3/rhgs-s3-server-rhel7"
)

### 이미지 다운로드 실행
for image in "${OSE_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}"; do
    echo "--- Pulling image: registry.redhat.io/$image ---"
    docker pull "registry.redhat.io/$image"
done
```

### 2.3. 이미지를 TAR 파일로 저장

다운로드한 모든 이미지를 `docker save` 명령을 사용하여 `.tar` 아카이브 파일로 만듭니다.

```bash
# 이미지를 저장할 디렉터리 생성
mkdir -p ose3-images
cd       ose3-images

OSE_TAG="v3.11.784"

### 필수 이미지를 TAR 파일로 저장
echo "--- Saving required OSE images to TAR file... ---"
# 배열의 각 요소를 registry.redhat.io/ 와 조합하여 전체 이미지 경로 생성
image_paths=()
for image in "${OSE_IMAGES[@]}"; do
    image_paths+=("registry.redhat.io/$image")
done
docker save -o "ose3-images-$OSE_TAG.tar" "${image_paths[@]}"

### 선택 이미지를 TAR 파일로 저장
echo "--- Saving optional OSE images to TAR file... ---"
image_paths=()
for image in "${OPTIONAL_IMAGES[@]}"; do
    image_paths+=("registry.redhat.io/$image")
done
docker save -o "ose3-optional-images-$OSE_TAG.tar" "${image_paths[@]}"

echo "--- Container images have been saved to TAR files. ---"
```

> **결과물**: `ose3-images` 디렉터리 안에 `ose3-images-v3.11.784.tar`와 `ose3-optional-images-v3.11.784.tar` 파일이 생성됩니다. 이 파일들을 오프라인 환경으로 복사하여, 각 노드에서 `docker load` 명령으로 이미지를 로드하거나 프라이빗 레지스트리에 Push해야 합니다.