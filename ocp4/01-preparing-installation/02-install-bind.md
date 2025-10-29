# RHEL에서 BIND DNS 서버 설정 가이드

이 문서는 Red Hat Enterprise Linux(RHEL) 시스템에 BIND DNS 서버를 설치하고 설정하는 과정을 단계별로 안내합니다.

-----

## 1. BIND 패키지 설치

먼저 `dnf` 패키지 관리자를 사용하여 **BIND**와 관련 유틸리티를 설치합니다.

```bash
dnf install -y bind
```

-----

## 2. 설정 파일 백업

설정을 변경하기 전에 원본 `named.conf` 파일을 백업합니다. 이 스크립트는 백업 파일(`.orig`)이 없을 경우에만 실행되어 원본을 안전하게 보존합니다.

```bash
if [[ ! -f /etc/named.conf.orig ]]; then
  cp /etc/named.conf /etc/named.conf.orig
fi
```

-----

## 3. BIND Configuration

DNS 서버의 핵심 동작 방식을 정의하는 메인 설정 파일과 각 도메인의 정보를 담을 존(Zone) 설정을 진행합니다.

### `named.conf` 수정

`/etc/named.conf` 파일의 `options` 블록을 수정하여 서버가 응답할 IP 주소, 쿼리 허용 범위 등을 설정합니다.

  * `listen-on port 53`: DNS 요청을 받을 서버의 IP 주소를 지정합니다.
  * `allow-query`: 어떤 클라이언트의 DNS 쿼리를 허용할지 정의합니다. (`any`는 모두 허용)
  * `recursion yes`: **재귀 쿼리(Recursive Query)를 허용합니다.** 이 설정은 서버가 모르는 도메인(예: https://www.google.com/search?q=google.com) 요청을 받았을 때, 다른 DNS 서버에 대신 물어봐서 답을 찾아주는 기능입니다. 내부 DNS 서버가 외부 인터넷 도메인도 함께 조회해야 할 때 사용합니다. **만약 외부로 쿼리를 보내지 않고 오직 내부 도메인만 응답하는 서버로 만들고 싶다면, 이 값을 `no`로 반드시 변경해야 합니다.**
  * `dnssec-enable no;`, `dnssec-validation no;`: DNSSEC 관련 기능을 비활성화합니다.

<!-- end list -->

```ini
options {
        // Change this to your server's actual IP address.
        listen-on port 53 { 11.119.120.28; };
        listen-on-v6 port 53 { ::1; };
        directory       "/var/named";
        dump-file       "/var/named/data/cache_dump.db";
        statistics-file "/var/named/data/named_stats.txt";
        memstatistics-file "/var/named/data/named_mem_stats.txt";
        secroots-file   "/var/named/data/named.secroots";
        recursing-file  "/var/named/data/named.recursing";
        allow-query     { any; };

        // Recursion settings:
        // 'yes' = Allows external domain lookups (acts as a caching DNS server).
        // 'no'  = Responds only for its authoritative domains (acts as an authoritative-only DNS server).
        recursion       yes;

        dnssec-enable   no;
        dnssec-validation no;
        managed-keys-directory "/var/named/dynamic";
        pid-file "/run/named/named.pid";
        session-keyfile "/run/named/session.key";
        include "/etc/crypto-policies/back-ends/bind.config";
};

// ... other settings ...

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
```

### 존(Zone) 설정 추가

`/etc/named.rfc1912.zones` 파일에 관리할 도메인(정방향 존)과 IP 대역(역방향 존)을 추가합니다.

```bash
cat <<EOF >> /etc/named.rfc1912.zones
zone "cloudpang.lan" IN {
        type master;
        file "cloudpang.lan.zone";
        allow-update { none; };
};
zone "ocp4-hub.cloudpang.lan" IN {
        type master;
        file "ocp4-hub.cloudpang.lan.zone";
        allow-update { none; };
};
zone "ocp4-mgc01.cloudpang.lan" IN {
        type master;
        file "ocp4-mgc01.cloudpang.lan.zone";
        allow-update { none; };
};
zone "120.119.11.in-addr.arpa" IN {
        type master;
        file "120.119.11-in-addr.zone";
        allow-update { none; };
};
EOF
```

-----

## 4. 존 파일 생성

위에서 정의한 각 존에 대한 상세 정보를 담은 파일을 `/var/named/` 디렉터리에 생성합니다.

### 정방향 존 파일 (도메인 → IP)

`cloudpang.lan.zone` 파일 생성:

```bash
cat <<EOF > /var/named/cloudpang.lan.zone
\$ORIGIN cloudpang.lan.
\$TTL 86400
@               IN      SOA     dns01.cloudpang.lan. hostmaster.cloudpang.lan. (
                                2025101701 ; Serial
                                21600      ; Refresh
                                3600       ; Retry
                                604800     ; Expire
                                86400 )    ; Minimum TTL
;
                IN      NS      dns01.cloudpang.lan.
;
dns01           IN      A       11.119.120.28
registry        IN      A       11.119.120.28
gitlab          IN      A       11.119.120.28
EOF
```

`ocp4-hub.cloudpang.lan.zone` 파일 생성:

```bash
cat <<EOF > /var/named/ocp4-hub.cloudpang.lan.zone
\$ORIGIN ocp4-hub.cloudpang.lan.
\$TTL 86400
@               IN      SOA     dns01.cloudpang.lan. hostmaster.cloudpang.lan. (
                                2025101701 ; Serial
                                21600      ; Refresh
                                3600       ; Retry
                                604800     ; Expire
                                86400 )    ; Minimum TTL
;
                IN      NS      dns01.cloudpang.lan.
;
registry        IN      A       11.119.120.28
;
api             IN      A       11.119.120.100
api-int         IN      A       11.119.120.100
*.apps          IN      A       11.119.120.100
;
sno             IN      A       11.119.120.100
;
EOF
```

`ocp4-mgc01.cloudpang.lan.zone` 파일 생성:

```bash
cat <<EOF > /var/named/ocp4-mgc01.cloudpang.lan.zone
\$ORIGIN ocp4-mgc01.cloudpang.lan.
\$TTL 86400
@               IN      SOA     dns01.cloudpang.lan. hostmaster.cloudpang.lan. (
                                2025101701 ; Serial
                                21600      ; Refresh
                                3600       ; Retry
                                604800     ; Expire
                                86400 )    ; Minimum TTL
;
                IN      NS      dns01.cloudpang.lan.
;
api             IN      A       11.119.120.28
api-int         IN      A       11.119.120.28
*.apps          IN      A       11.119.120.28
;
mst01           IN      A       11.119.120.111
mst02           IN      A       11.119.120.112
mst03           IN      A       11.119.120.113
ifr01           IN      A       11.119.120.121
ifr02           IN      A       11.119.120.122
wrk01           IN      A       11.119.120.131
wrk02           IN      A       11.119.120.132
;
EOF
```

### 역방향 존 파일 (IP → 도메인)

`120.119.11-in-addr.zone` 파일 생성:

```bash
cat <<EOF > /var/named/120.119.11-in-addr.zone
\$ORIGIN 120.119.11.in-addr.arpa.
\$TTL 86400
@               IN      SOA     dns01.cloudpang.lan. hostmaster.cloudpang.lan. (
                                2025101702 ; Serial
                                21600      ; Refresh
                                3600       ; Retry
                                604800     ; Expire
                                86400 )    ; Minimum TTL
;
                IN      NS                   dns01.cloudpang.lan.
;
100             IN      PTR           api.ocp4-hub.cloudpang.lan.
100             IN      PTR       api-int.ocp4-hub.cloudpang.lan.
;
100             IN      PTR           sno.ocp4-hub.cloudpang.lan.
;
28              IN      PTR         api.ocp4-mgc01.cloudpang.lan.
28              IN      PTR     api-int.ocp4-mgc01.cloudpang.lan.
;
111             IN      PTR       mst01.ocp4-mgc01.cloudpang.lan.
112             IN      PTR       mst02.ocp4-mgc01.cloudpang.lan.
113             IN      PTR       mst03.ocp4-mgc01.cloudpang.lan.
121             IN      PTR       ifr01.ocp4-mgc01.cloudpang.lan.
122             IN      PTR       ifr02.ocp4-mgc01.cloudpang.lan.
131             IN      PTR       wrk01.ocp4-mgc01.cloudpang.lan.
132             IN      PTR       wrk02.ocp4-mgc01.cloudpang.lan.
;
EOF
```

-----

## 5. 파일 권한 및 SELinux 컨텍스트 설정

`named` 데몬이 새로 생성된 존 파일을 읽을 수 있도록 파일 소유권과 SELinux 보안 컨텍스트를 올바르게 설정합니다.

```bash
# Change file owner to root and group to named
chown root:named /var/named/cloudpang.lan.zone
chown root:named /var/named/ocp4-hub.cloudpang.lan.zone
chown root:named /var/named/ocp4-mgc01.cloudpang.lan.zone
chown root:named /var/named/120.119.11-in-addr.zone

# Set the correct SELinux context by referencing an existing BIND file
chcon --reference=/var/named/named.empty /var/named/cloudpang.lan.zone
chcon --reference=/var/named/named.empty /var/named/ocp4-hub.cloudpang.lan.zone
chcon --reference=/var/named/named.empty /var/named/ocp4-mgc01.cloudpang.lan.zone
chcon --reference=/var/named/named.empty /var/named/120.119.11-in-addr.zone
```

-----

## 6. 설정 유효성 검사

서비스를 시작하기 전에 `named-checkzone` 명령어로 존 파일에 문법적 오류가 없는지 확인합니다. "OK" 메시지가 출력되면 정상입니다.

```bash
/usr/sbin/named-checkzone            cloudpang.lan /var/named/cloudpang.lan.zone
/usr/sbin/named-checkzone   ocp4-hub.cloudpang.lan /var/named/ocp4-hub.cloudpang.lan.zone
/usr/sbin/named-checkzone ocp4-mgc01.cloudpang.lan /var/named/ocp4-mgc01.cloudpang.lan.zone
/usr/sbin/named-checkzone 120.119.11.in-addr.arpa  /var/named/120.119.11-in-addr.zone
```

-----

## 7. 서비스 실행 및 방화벽 설정

모든 설정이 완료되면 `named` 서비스를 시스템에 등록하고 시작합니다. 또한, 외부에서 DNS 쿼리가 가능하도록 방화벽에서 DNS 포트(53/UDP)를 열어줍니다.

```bash
# Enable and start the named service
systemctl enable named.service
systemctl start named.service

# Permanently add the dns service to the firewall and reload
firewall-cmd --permanent --add-service=dns --zone=public
firewall-cmd --reload
```

-----

이제 모든 설정이 완료되었습니다. `dig`이나 `nslookup` 같은 명령어를 사용하여 DNS 서버가 정상적으로 작동하는지 테스트해 보세요.