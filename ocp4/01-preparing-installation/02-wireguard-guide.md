
## WireGuard를 이용한 사설망(`172.16.120.0/24`) 직접 접속 가이드

이 가이드는 DNS가 **VM의 실제 사설 IP**(`172.16.120.x`)를 반환하도록 설정합니다. 이 구성을 통해 모바일 폰이나 Mac 같은 클라이언트가 사설망에 완벽하게 통합될 수 있습니다.

**전제 조건:**

  * WireGuard 서버(RHEL)가 이미 `172.16.120.0/24` 네트워크에 (예: `enp1s0`) 연결되어 있다고 가정합니다.
  * `named` (DNS 서버)가 이미 설치되어 있다고 가정합니다.

### 새로운 네트워크 구성

  * **사설 LAN (VM):** `172.16.120.0/24`
  * **WireGuard VPN 네트워크:** `10.10.0.0/24` (사설 LAN과 충돌을 피하기 위한 별도 VPN 대역)
  * **WireGuard 서버 IP:** `10.10.0.1` (VPN 대역)
  * **Android 클라이언트 IP:** `10.10.0.2` (VPN 대역)
  * **Mac 클라이언트 IP:** `10.10.0.3` (VPN 대역)
  * **DNS 서버:** `10.10.0.1` (WireGuard 서버가 DNS 역할 겸임)
  * **도메인:** `cloudpang.lan`

-----

### 1\. WireGuard 서버 설치 및 키 생성

```bash
### 1. 설치
dnf install -y wireguard-tools

### 2. 키 생성
wg genkey | tee /etc/wireguard/$(hostname).private.key | wg pubkey | tee /etc/wireguard/$(hostname).public.key
chmod 600 /etc/wireguard/$(hostname).private.key /etc/wireguard/$(hostname).public.key

### 3. 키 확인 (이 값들은 나중에 사용)
cat /etc/wireguard/$(hostname).private.key
cat /etc/wireguard/$(hostname).public.key
```

-----

### 2\. nmcli를 사용하여 WireGuard 서버 구성

VPN 네트워크를 `10.10.0.1/24`로 설정하고, `IP 포워딩(NAT)`을 활성화하여 VPN 클라이언트가 사설 LAN(`172.16.120.0/24`)에 도달할 수 있도록 합니다.

```bash
### 1. WireGuard 연결 생성
nmcli connection add type wireguard con-name server-wg0 ifname wg0 autoconnect no

### 2. VPN IP 대역 설정 (10.10.0.1/24)
nmcli connection modify server-wg0 ipv4.method manual ipv4.addresses 10.10.0.1/24

### 3. 개인키 및 포트 설정
nmcli connection modify server-wg0 wireguard.private-key "$(cat /etc/wireguard/$(hostname).private.key)"
nmcli connection modify server-wg0 wireguard.listen-port 51820

### 4. (중요) IP 포워딩 활성화
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard-forward.conf

### 5. (중요) 방화벽 설정: VPN 트래픽이 사설 LAN으로 NAT(Masquerade) 되도록 설정
# 5a. 외부(public)에서 VPN 포트 허용
firewall-cmd --permanent --zone=public --add-port=51820/udp

# 5b. wg0 인터페이스를 'internal' 존에 할당
# (참고: 사설 LAN 인터페이스(enp1s0)도 internal 존에 있는 것이 관리상 편함)
firewall-cmd --permanent --zone=internal --add-interface=wg0
# firewall-cmd --permanent --zone=internal --add-interface=enp1s0

# 5c. internal 존에 NAT(Masquerade) 활성화
# 이렇게 하면 internal(wg0) -> internal(enp1s0)으로의 트래픽이 서버의 LAN IP로 NAT 처리됨
firewall-cmd --permanent --zone=internal --add-masquerade

# 5d. 방화벽 리로드
firewall-cmd --reload

### 6. 연결 활성화
nmcli connection modify server-wg0 autoconnect yes
nmcli con up server-wg0
```

-----

### 3\. DNS 서버 구성 (`named`)

`cloudpang.lan` 도메인이 **VM의 실제 사설 IP**를 반환하도록 `named` 설정을 변경합니다.

> **파일: `/etc/named.conf`**
>
> `options { ... }` 블록 내부를 수정합니다.

```text
...
    listen-on port 53 { 127.0.0.1; 10.10.0.1; 172.16.120.x; }; // 10.10.0.1(VPN) 및 서버의 사설 LAN IP 추가
    ...
    allow-query    { localhost; 10.10.0.0/24; 172.16.120.0/24; }; // VPN 대역 및 사설 LAN 대역 추가
...
```

  * **참고:** `172.16.120.x`는 WireGuard 서버의 사설 LAN IP (예: `172.16.120.29`)로 변경해야 합니다.
  * 설정 변경 후 `named` 서비스를 재시작합니다: `systemctl restart named`

-----

### 4\. WireGuard Client 설정 (Android)

모바일 폰이 사설 LAN(`172.16.120.0/24`) 대역으로 향하는 트래픽을 VPN 터널로 보내도록 설정합니다.

1.  WireGuard 앱 실행 \> "+" 버튼 \> "직접 만들기"
2.  **[Interface] 설정**
      * **이름**: `Private-LAN` (임의 설정)
      * **개인키/공개키**: 자동 생성 (이 **공개키**를 복사하여 5단계에서 사용)
      * **주소**: `10.10.0.2/32` (클라이언트의 VPN IP)
      * **DNS 서버**: `10.10.0.1` (3단계에서 설정한 서버의 VPN IP)
3.  **[Interface] \> (선택) 앱별 터널링**
      * `Termux(터미널)`, `Whale(브라우저)` 등 사설망에 접속할 앱만 선택
4.  **[Peer] 추가**
      * **공개키**: WireGuard **서버**의 공개키 (1단계에서 확인한 값)
      * **엔드포인트**: **`<WireGuard 서버 공인 IP>:51820`**
      * **(★핵심★) 허용된 IP**:
          * `10.10.0.0/24` (VPN 네트워크 자체 접근용)
          * `172.16.120.0/24` (VM이 있는 사설 LAN 접근용)
          * *(쉼표로 구분하여 두 개 모두 입력: `10.10.0.0/24, 172.16.120.0/24`)*

-----

### 5\. 서버에 Android Peer 추가

`nmtui`를 사용하여 4단계에서 생성한 모바일 폰(클라이언트)을 서버에 등록합니다.

1.  터미널에서 `nmtui` 실행
2.  `Edit a connection` 선택
3.  `server-wg0` 선택 후 `<Edit...>`
4.  `WireGuard peers` 항목에서 `<Add...>` 버튼 클릭
      * **Public Key**: **모바일 폰**(클라이언트)의 공개키 (4단계에서 복사한 값)
      * **Allowed IP**: `10.10.0.2/32` (이 클라이언트에게 할당할 고유 IP)
      * **Persistent keepalive**: `20` (권장)
5.  `<OK>`를 눌러 저장 후 `nmtui` 종료
6.  `server-wg0` 연결 재시작
    ```bash
    nmcli con up server-wg0
    ```

-----

### 6\. WireGuard Client 설정 (Mac)

Mac 클라이언트가 사설 LAN 대역으로 트래픽을 보낼 수 있도록 설정합니다. (IP: `10.10.0.3` 할당)

1.  App Store에서 WireGuard를 설치 및 실행
2.  `+` 버튼 \> `Add Empty Tunnel...` 클릭
3.  설정 창이 뜨면, \*\*[Interface]\*\*의 **PrivateKey**는 자동 생성됩니다. (이 **PublicKey**를 복사하여 7단계에서 사용)
4.  아래 내용을 붙여넣고, `[ ]` 안의 값을 수정합니다.

<!-- end list -->

```ini
[Interface]
# PrivateKey는 자동 생성된 값을 유지합니다.
PrivateKey = <자동 생성된 Mac의 PrivateKey>
# Mac 클라이언트에 할당할 VPN IP
Address = 10.10.0.3/32
# DNS 서버는 WireGuard 서버의 VPN IP로 설정
DNS = 10.10.0.1

[Peer]
# 1단계에서 확인한 WireGuard 서버의 공개키
PublicKey = <서버의 Public Key>

# (★핵심★) Android와 동일하게 설정
AllowedIPs = 10.10.0.0/24, 172.16.120.0/24

# WireGuard 서버의 공인 IP 및 포트
Endpoint = <WireGuard 서버 공인 IP>:51820
PersistentKeepalive = 20
```

5.  **Name** 필드에 `Private-LAN` (임의)을 입력하고 `Save`를 누릅니다.
6.  (선택 사항) `On-Demand` 설정을 통해 Wi-Fi나 Ethernet 연결 시 자동 실행되도록 설정할 수 있습니다.

-----

### 7\. 서버에 Mac Peer 추가

`nmtui`를 사용하여 6단계에서 생성한 Mac 클라이언트를 서버에 등록합니다.

1.  터미널에서 `nmtui` 실행
2.  `Edit a connection` \> `server-wg0` \> `<Edit...>`
3.  `WireGuard peers` 항목에서 `<Add...>` 버튼 클릭 (기존 Android Peer 아래)
      * **Public Key**: **Mac 클라이언트**의 공개키 (6단계에서 확인한 값)
      * **Allowed IP**: `10.10.0.3/32` (이 클라이언트에게 할당할 고유 IP)
      * **Persistent keepalive**: `20` (권장)
4.  `<OK>`를 눌러 저장 후 `nmtui` 종료
5.  `server-wg0` 연결 재시작
    ```bash
    nmcli con up server-wg0
    ```