
-----

# RHEL Host Configuration Guide

이 문서는 Red Hat Enterprise Linux (RHEL) 호스트를 설정하는 과정을 단계별로 안내합니다. 시스템 등록부터 가상화, 네트워크 및 기타 유틸리티 설정까지 다룹니다.

## 1. Red Hat Subscription

시스템을 등록하고 필요한 리포지토리를 활성화합니다.

```bash
# 시스템 등록
subscription-manager register

# 사용 가능한 구독 목록에서 "... SKU"와 일치하는 항목을 찾아 Pool ID 확인
subscription-manager list --available --matches "... SKU" | egrep "Pool ID|^Ends"

# 확인한 Pool ID를 사용하여 시스템에 구독 연결
subscription-manager attach --pool=<Pool ID>

# 활성화된 리포지토리 목록 확인
subscription-manager repos --list-enabled
```

-----

## 2. System Update & GUI Customization

시스템을 최신 상태로 업데이트하고, GUI 환경을 개선하기 위한 도구와 폰트를 설치합니다.

### System Update

```bash
dnf update -y
```

### GNOME Tweaks 설치

RHEL의 GNOME 데스크톱 환경을 세밀하게 조정할 수 있는 `gnome-tweaks` 도구를 설치합니다.
(설치 후 "Show Applications" -> "Utilities"에서 찾을 수 있습니다.)

```bash
dnf install -y gnome-tweaks
```

### 한글 입력기 설정

```bash
dnf install @input-methods
```

  - **수동 설정**: `Settings` > `Keyboard` > `Input Sources`에서 `Korean (Hangul)`을 추가합니다.

### D2Coding 폰트 설치

가독성이 뛰어난 코딩용 D2Coding 폰트를 시스템에 추가합니다.

```bash
# D2Coding 폰트 다운로드 (버전: 1.3.2)
wget https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip

# 압축 해제
unzip D2Coding-Ver1.3.2-20180524.zip

# 폰트 디렉토리 생성
mkdir -p /usr/share/fonts/D2Coding

# 폰트 파일 복사
cp ./D2CodingAll/D2Coding-Ver1.3.2-20180524-all.ttc /usr/share/fonts/D2Coding/

# 폰트 캐시 갱신
fc-cache -v
```

-----

## 3. Enable Virtualization (KVM)

KVM을 사용하여 가상 머신을 호스팅하기 위한 패키지를 설치하고 관련 서비스를 활성화합니다.

### Virtualization Packages 설치

```bash
dnf install -y qemu-kvm libvirt virt-install virt-viewer
```

### Virtualization Services 시작

```bash
for drv in qemu network nodedev nwfilter secret storage interface; do
    systemctl start virt${drv}d{,-ro,-admin}.socket
done
```

### 호스트 유효성 검사 및 libvirtd 서비스 관리

```bash
# 가상화 호스트 환경 검사
virt-host-validate

# libvirtd 서비스 시작 및 활성화
systemctl start libvirtd.service
systemctl enable libvirtd.service

# 서비스 활성화 및 상태 확인
systemctl is-enabled libvirtd.service
systemctl status libvirtd.service
```

### IOMMU 활성화 (필요 시)

`virt-host-validate` 실행 시 IOMMU 관련 경고가 나타나는 경우, 아래 명령어로 커널 파라미터를 추가하여 해결합니다.

```bash
# 현재 커널 정보 확인
grubby --info DEFAULT

# intel_iommu=on 파라미터 추가
grubby --args intel_iommu=on --update-kernel DEFAULT

# 변경된 커널 정보 재확인
grubby --info DEFAULT
```

> **참고**: RHEL 8부터 `virt-manager`는 지원은 되지만 deprecated 상태입니다. 대신 Web Console 사용을 권장합니다.
>
> ```bash
> # yum -y install virt-manager
> ```

-----

## 4. Setup Web Console for VMs

웹 브라우저를 통해 가상 머신을 관리할 수 있도록 Cockpit과 관련 모듈을 설치합니다.

```bash
# Cockpit의 가상 머신 관리 모듈 설치
dnf -y install cockpit-machines

# Cockpit 소켓 서비스 활성화 및 시작
systemctl enable cockpit.socket
systemctl is-enabled cockpit.socket

systemctl start cockpit.socket
systemctl status cockpit.socket
```

-----

## 5. NTP Server (chrony)

정확한 시간 동기화를 위해 chrony NTP 서버를 설치하고 설정합니다.

### chrony 설치

```bash
dnf install -y chrony
```

### chrony 설정

```bash
# 기존 설정 파일 백업
if [[ ! -f /etc/chrony.conf.orig ]]; then
  mv /etc/chrony.conf /etc/chrony.conf.orig
fi

# 새로운 설정 파일 생성
cat <<EOF > /etc/chrony.conf
pool 2.rhel.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow all
local stratum 10
keyfile /etc/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF

# SELinux 컨텍스트 복원
chcon --reference=/etc/chrony.conf.orig /etc/chrony.conf
```

### chronyd 서비스 및 방화벽 설정

```bash
# chronyd 서비스 활성화 및 시작
systemctl enable chronyd
systemctl start chronyd

# 방화벽에서 NTP 서비스 허용
firewall-cmd --permanent --add-service=ntp --zone=public
firewall-cmd --reload
```

### 동기화 상태 확인

```bash
# 시간 동기화 추적 정보 확인
chronyc tracking

# 연결된 시간 소스 확인
chronyc sources
```

-----

## 6. 네트워크 브리지(bridge0) 생성

가상 머신(VM)이 외부 네트워크와 직접 통신할 수 있도록 **네트워크 브리지(`bridge0`)**를 생성합니다. 브리지를 사용하면 VM이 호스트와 동일한 네트워크 대역의 IP를 할당받아 마치 별개의 물리적 머신처럼 동작하게 됩니다.
여기서는 **Cockpit 웹 콘솔**을 사용하여 간편하게 생성하는 방법을 안내합니다.
### 생성 방법 (Cockpit 웹 콘솔)
1.  웹 브라우저에서 Cockpit 주소(`https://<호스트_IP>:9090`)로 접속하여 로그인합니다.
2.  왼쪽 메뉴에서 **"네트워킹(Networking)"**을 클릭합니다.
3.  네트워크 인터페이스 목록 우측 상단의 **"브리지 추가(Add Bridge)"** 버튼을 누릅니다.
4.  아래와 같이 설정하고 **"만들기(Create)"** 버튼을 클릭합니다.
    * **이름(Name):** `bridge0`
    * **포트(Ports):** VM을 연결할 호스트의 물리적 네트워크 인터페이스(예: `enp1s0`)를 선택합니다.
생성이 완료되면 `bridge0`는 VM의 네트워크 인터페이스로 사용할 수 있는 상태가 됩니다.

-----

## 7. SSH Key Management

원격 서버에 비밀번호 없이 안전하게 접속하기 위해 SSH 키를 생성하고 관리합니다.

### SSH Key 생성

`~/.ssh/id_ed25519` 파일이 없을 경우에만 새로운 키를 생성합니다.

```bash
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  # ed25519 타입의 SSH 키를 암호 없이 생성
  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
else
  # 파일이 이미 존재하면 정보만 출력
  ls -al ~/.ssh/id_ed25519
  echo ""
fi

# SSH 에이전트를 백그라운드로 실행
eval "$(ssh-agent -s)"

# 생성한 키를 SSH 에이전트에 등록
ssh-add ~/.ssh/id_ed25519
```

### 공개 키 원격 서버에 복사

로컬에 생성된 공개 키를 원격 서버의 `~/.ssh/authorized_keys` 파일에 추가합니다.

```bash
ssh-copy-id <username>@<ssh-server-example.com>
```