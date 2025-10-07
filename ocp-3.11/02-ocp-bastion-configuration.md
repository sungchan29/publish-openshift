# OpenShift 3.11 오프라인 설치를 위한 Bastion 서버 구성 가이드

이 문서는 인터넷이 차단된(Disconnected/Air-gapped) 환경에 OpenShift Container Platform 3.11을 설치하기 위해, 필요한 모든 패키지와 컨테이너 이미지를 제공하는 Bastion 서버를 구성하는 단계별 절차를 안내합니다.

## 사전 준비 사항

  - **RHEL 7.x 서버**: Bastion 서버로 사용할 최소 사양의 RHEL 7.x 서버 1대
  - **Red Hat 서브스크립션**: 유효한 Red Hat 계정 및 서브스크립션
  - **OCP 리소스 파일**:
      - **RPM 패키지**: `reposync`를 통해 미리 받아둔 RPM 패키지 `tar` 아카이브 (예: `ocp-3.11-rpms.tar`)
      - **컨테이너 이미지**: `docker save`를 통해 미리 받아둔 컨테이너 이미지 `tar` 아카이브 (예: `ose3-images-v3.11.784.tar` 등)
  - **추가 디스크**: Docker 스토리지를 위한 별도의 디스크 (예: `/dev/vdb`)

-----

## 1단계: 로컬 Yum 리포지토리 설정

Bastion 서버 및 모든 OCP 노드들이 사용할 Yum 리포지토리를 HTTP를 통해 제공하도록 설정합니다.

### 1.1. RPM 패키지 압축 해제

미리 준비한 RPM 패키지 `tar` 파일을 `/var/repos` 디렉터리에 압축 해제합니다.

```bash
mkdir -p /var/repos
tar xvf ocp-3.11-rpms.tar -C /var/repos
```

### 1.2. 로컬 파일 기반 리포지토리 설정

`httpd` 웹 서버를 설치하기 위해, 먼저 파일 시스템 경로를 직접 바라보는 임시 Yum 리포지토리를 설정합니다.

```bash
cat <<EOF > /etc/yum.repos.d/local-file.repo
[rhel-7-server-rpms-local]
name=rhel-7-server-rpms
baseurl=file:///var/repos/lmn/rhel-7-server-rpms
enabled=1
gpgcheck=0

[rhel-7-server-extras-rpms-local]
name=rhel-7-server-extras-rpms
baseurl=file:///var/repos/lmn/rhel-7-server-extras-rpms
enabled=1
gpgcheck=0

[rhel-7-server-ansible-2.9-rpms-local]
name=rhel-7-server-ansible-2.9-rpms
baseurl=file:///var/repos/lmn/rhel-7-server-ansible-2.9-rpms
enabled=1
gpgcheck=0

[rhel-7-server-ose-3.11-rpms-local]
name=rhel-7-server-ose-3.11-rpms
baseurl=file:///var/repos/lmn/rhel-7-server-ose-3.11-rpms
enabled=1
gpgcheck=0
EOF
```

```bash
yum repolist
```

### 1.3. 웹 서버(httpd) 설치 및 설정

RPM 패키지를 네트워크를 통해 제공하기 위해 `httpd`를 설치하고 설정합니다.

```bash
yum install -y httpd

# Apache 사용자를 root 그룹에 추가하여 권한 문제 방지
usermod -a -G root apache
```

### 1.4. 리포지토리 웹 디렉터리 링크 및 권한 설정

`httpd`의 웹 루트 디렉터리(`/var/www/html`)에 RPM 패키지가 있는 디렉터리를 심볼릭 링크로 연결하고, 파일 접근에 필요한 권한 및 SELinux 컨텍스트를 설정합니다.

```bash
mkdir -p /var/www/html/repos
ln -s /var/repos/lmn /var/www/html/repos/lmn

chown -R root:root /var/www/html
chmod -R 755 /var/www/html  # 실행 권한 추가
chcon -Rv --reference /var/www/html /var/www/html/repos/lmn

systemctl enable httpd
systemctl restart httpd

firewall-cmd --permanent --add-service=http --zone=public
firewall-cmd --reload
```

### 1.5. HTTP 기반 리포지토리로 전환

이제 Bastion 서버 자신도 다른 노드들과 동일하게 HTTP를 통해 리포지토리를 사용하도록 설정을 변경합니다.

```bash
# 기존 파일 기반 리포지토리 설정 삭제
rm -f /etc/yum.repos.d/local-file.repo

# Bastion 서버의 호스트 이름 또는 IP
REPO_SERVER="http://bst01.ocp3.cloudpang.lan"

cat <<EOF > /etc/yum.repos.d/redhat.repo
[rhel-7-server-rpms]
name=rhel-7-server-rpms
baseurl=$REPO_SERVER/repos/lmn/rhel-7-server-rpms
enabled=1
gpgcheck=0

[rhel-7-server-extras-rpms]
name=rhel-7-server-extras-rpms
baseurl=$REPO_SERVER/repos/lmn/rhel-7-server-extras-rpms
enabled=1
gpgcheck=0

[rhel-7-server-ansible-2.9-rpms]
name=rhel-7-server-ansible-2.9-rpms
baseurl=$REPO_SERVER/repos/lmn/rhel-7-server-ansible-2.9-rpms
enabled=1
gpgcheck=0

[rhel-7-server-ose-3.11-rpms]
name=rhel-7-server-ose-3.11-rpms
baseurl=$REPO_SERVER/repos/lmn/rhel-7-server-ose-3.11-rpms
enabled=1
gpgcheck=0
EOF
```

### 1.6. 리포지토리 적용 및 시스템 업데이트

새로운 리포지토리 설정을 적용하고 시스템을 최신 상태로 업데이트합니다. 필수 유틸리티도 함께 설치합니다.

```bash
yum clean all
yum repolist
yum update -y
yum install -y wget git net-tools bind-utils yum-utils bridge-utils bash-completion kexec-tools sos psacct chrony
```

### 1.7. 시간 동기화(NTP) 설정

`chrony` 서비스를 설정하여 Bastion 서버의 시간을 정확하게 유지합니다.

```bash
# /etc/chrony.conf 파일에 NTP 서버 주소를 설정합니다.
vi /etc/chrony.conf

# chrony 서비스 시작 및 활성화
systemctl enable chronyd.service
systemctl start  chronyd.service
sleep 5
chronyc sources
```

> **이제 모든 노드는 이 Bastion 서버를 Yum 리포지토리로 사용하게 됩니다.**

-----

## 2단계: 로컬 DNS 서버 설정 (BIND)

클러스터 내부 및 외부 도메인 질의를 처리할 DNS 서버를 Bastion 서버에 구축합니다.

### 2.1. BIND 설치 및 기본 설정

`bind` 패키지를 설치하고, 외부 쿼리를 허용하도록 `/etc/named.conf` 파일을 수정합니다.

```bash
yum install -y bind

# /etc/named.conf 파일 수정 (아래는 주요 수정 부분 예시)
# listen-on port 53 { any; };
# allow-query     { any; };
vi /etc/named.conf
```

### 2.2. Zone 파일 설정

관리할 도메인(예: `cloudpang.lan`)에 대한 Zone 설정을 추가하고, 해당 Zone 파일을 생성합니다.

```bash
# /etc/named.rfc1912.zones 파일에 Zone 정보 추가
cat <<EOF >> /etc/named.rfc1912.zones
zone "cloudpang.lan" IN {
        type master;
        file "cloudpang.lan.zone";
        allow-update { none; };
};
EOF
```

다음으로, 선언한 `cloudpang.lan.zone` 파일을 생성하고 OCP 클러스터 설치 및 운영에 필요한 모든 호스트의 DNS 레코드(A 레코드)를 등록합니다.

> **💡 고가용성(HA) 및 로드 밸런서(LB) 정보**
>
> OCP 클러스터의 API 엔드포인트 역할을 하는 `master.ocp3.cloudpang.lan`과 `csmaster.ocp3.cloudpang.lan`은 **고가용성(HA) 환경에서는 보통 로드 밸런서(LB)의 가상 IP**를 가리킵니다.
>
> 하지만 별도의 LB(11.119.120.29)가 없는 테스트 환경에서는, OCP 클러스터의 API 엔드포인트를 **첫 번째 마스터 노드(`mst01`)의 IP를 직접 지정**해도 클러스터 설치 및 기능에 문제가 없습니다.

```bash
# /var/named/cloudpang.lan.zone 파일 생성 (OCP 노드들의 호스트 이름과 IP 등록)
cat <<EOF > /var/named/cloudpang.lan.zone
\$ORIGIN cloudpang.lan.
\$TTL 86400
@               IN      SOA     dns01.cloudpang.lan. hostmaster.cloudpang.lan. (
                                2025061701 ; Serial
                                21600      ; Refresh
                                3600       ; Retry
                                604800     ; Expire
                                86400 )    ; Minimum TTL
;
                IN      NS      dns01.cloudpang.lan.
;
dns01           IN      A       11.119.120.100
;
bst01.ocp3      IN      A       11.119.120.100
;
master.ocp3     IN      A       11.119.120.29
csmaster.ocp3   IN      A       11.119.120.29
;
*.apps.ocp3     IN      A       11.119.120.29
;
mst01.ocp3      IN      A       11.119.120.111
mst02.ocp3      IN      A       11.119.120.112
mst03.ocp3      IN      A       11.119.120.113
ifr01.ocp3      IN      A       11.119.120.121
ifr02.ocp3      IN      A       11.119.120.122
ifr03.ocp3      IN      A       11.119.120.123
wrk01.ocp3      IN      A       11.119.120.131
wrk02.ocp3      IN      A       11.119.120.132
;
EOF
```

### 2.3. 권한 설정 및 서비스 시작

Zone 파일의 권한과 SELinux 컨텍스트를 설정하고, 문법 검사 후 서비스를 시작합니다.

```bash
# 파일 소유권 및 SELinux 컨텍스트 설정
chown root:named /var/named/cloudpang.lan.zone
chcon --reference=/var/named/named.empty /var/named/cloudpang.lan.zone

# Zone 파일 문법 검사 ("OK" 출력 확인)
named-checkzone cloudpang.lan /var/named/cloudpang.lan.zone

# named 서비스 시작 및 활성화
systemctl enable named.service
systemctl start named.service

# 방화벽에서 DNS 서비스 포트 허용
firewall-cmd --permanent --add-service=dns --zone=public
firewall-cmd --reload
```

> **이제 모든 노드는 이 Bastion 서버를 DNS 서버로 사용하게 됩니다.**

-----

## 3단계: Docker 설치 및 스토리지 구성

컨테이너 이미지를 저장하고 관리하기 위해 Docker를 설치하고, 안정적인 운영을 위해 LVM 기반의 전용 스토리지를 구성합니다.

### 3.1. Docker 설치 및 Docker 스토리지 설정
Docker가 사용할 디스크(예: `/dev/vdb`)를 Docker 스토리지로 사용하도록 설정합니다.

```bash
yum install -y docker-1.13.1

DOCKER_STORAGE_DISK="/dev/vdb"

# Docker 스토리지 설정 파일 생성
cat <<EOF > /etc/sysconfig/docker-storage-setup
STORAGE_DRIVER=overlay2
DEVS=${DOCKER_STORAGE_DISK}
VG=docker-vg
CONTAINER_ROOT_LV_NAME=docker
CONTAINER_ROOT_LV_SIZE=100%FREE
CONTAINER_ROOT_LV_MOUNT_PATH=/var/lib/docker
EOF

# 설정 기반으로 Docker 스토리지 자동 구성
docker-storage-setup
```

### 3.2. Docker 서비스 시작 및 확인

Docker 서비스를 시작하고, `docker info`를 통해 `Storage Driver`가 `overlay2`로, `Backing Filesystem`이 `xfs`로 올바르게 설정되었는지 확인합니다.

```bash
systemctl enable docker
systemctl start docker

# Docker 설정 정보 확인
docker info
```

-----

## 4단계: 로컬 Docker 레지스트리 설정

오프라인 OCP 노드들이 컨테이너 이미지를 받아갈 수 있도록 `docker-distribution`을 사용하여 프라이빗 레지스트리를 구축합니다.

### 4.1. Docker Distribution 설치 및 서비스 시작

패키지를 설치하고 방화벽 포트(5000)를 연 다음, 서비스를 시작합니다.

```bash
yum install -y docker-distribution

firewall-cmd --permanent --add-port=5000/tcp --zone=public
firewall-cmd --reload

systemctl enable docker-distribution
systemctl start docker-distribution
```

### 4.2. Insecure Registry 등록

Bastion 서버 자신도 이 레지스트리(HTTP 기반)를 신뢰할 수 있도록 `/etc/containers/registries.conf` 파일에 주소를 등록합니다. **(이 설정은 모든 OCP 노드에도 동일하게 적용되어야 합니다.)**

```bash
# /etc/containers/registries.conf 파일 수정 예시
# [registries.insecure]
# registries = ['bst01.ocp3.cloudpang.lan:5000']
vi /etc/containers/registries.conf
```

```bash
# 변경사항 적용을 위해 Docker 서비스 재시작
systemctl restart docker.service
```

-----

## 5단계: 컨테이너 이미지 로드 및 미러링

미리 준비한 이미지 `tar` 파일을 로드하여 로컬 Docker 레지스트리로 Push합니다.

### 5.1. TAR 파일에서 이미지 로드

```bash
OSE_TAG="v3.11.784"
docker load -i ose3-images-$OSE_TAG.tar
docker load -i ose3-optional-images-$OSE_TAG.tar
```

### 5.2. 이미지 리태깅 (Retagging)

`registry.redhat.io`로 되어 있는 이미지 이름들을 로컬 레지스트리 주소(예: `bst01.ocp3.cloudpang.lan:5000`)로 변경하는 태그를 새로 생성합니다.

```bash
MIRROR_REGISTRY="bst01.ocp3.cloudpang.lan:5000"

docker images --format "{{.Repository}}:{{.Tag}}" | grep "registry.redhat.io" | while read -r image; do
  new_image="${image/registry.redhat.io/$MIRROR_REGISTRY}"
  echo "Tagging: ${image} -> ${new_image}"
  docker tag "${image}" "${new_image}"
done
```

### 5.3. 로컬 레지스트리로 이미지 푸시 (Push)

새로 태그된 이미지들을 로컬 레지스트리로 모두 Push합니다.

```bash
MIRROR_REGISTRY="bst01.ocp3.cloudpang.lan:5000"
docker images --format "{{.Repository}}:{{.Tag}}" | grep "$MIRROR_REGISTRY" | xargs -I {} docker push {}
```

### 5.4. (선택) 레지스트리 업로드 확인

아래 스크립트를 실행하여 로컬 레지스트리에 저장된 이미지 목록을 확인할 수 있습니다.

```bash
CONFIG_FILE=$(grep -l 'rootdirectory:' /etc/docker-distribution/registry/config.yml)
ROOT_DIRECTORY=$(grep 'rootdirectory:' "$CONFIG_FILE" | awk '{print $2}')
echo "Listing images found in registry at: $ROOT_DIRECTORY"
find "$ROOT_DIRECTORY/docker/registry/v2/repositories" -type d -name 'current' | sed -E "s|${ROOT_DIRECTORY}/docker/registry/v2/repositories/(.*)/_manifests/tags/(.*)/current|\1:\2|"
```

> **이제 Bastion 서버 구성이 완료되었습니다. 이 서버를 기반으로 오프라인 OpenShift 3.11 클러스터 설치를 진행할 수 있습니다.**