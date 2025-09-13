
-----

# RHEL에서 NFS 서버 설정하기

이 문서는 Red Hat Enterprise Linux(RHEL) 시스템에서 NFS(Network File System) 서버를 설치하고 설정하는 방법을 안내합니다.

## 1. 패키지 설치

NFS 서버를 구축하기 위해 `nfs-utils` 패키지를 설치합니다. 이 패키지에는 NFS 서버 및 클라이언트에 필요한 모든 유틸리티가 포함되어 있습니다.

```bash
dnf install -y nfs-utils
```

-----

## 2. 서비스 활성화

NFS는 RPC(Remote Procedure Call)를 사용하므로 `rpcbind`와 `nfs-server` 서비스를 활성화하고 시작해야 합니다. `--now` 옵션은 활성화와 동시에 서비스를 즉시 시작합니다.

  * **rpcbind 서비스**

    ```bash
    systemctl enable rpcbind --now
    ```

  * **nfs-server 서비스**

    ```bash
    systemctl enable nfs-server --now
    ```

-----

## 3. 방화벽 설정

외부 클라이언트가 NFS 서버에 접근할 수 있도록 방화벽에서 관련 서비스들을 영구적으로 허용해야 합니다.

```bash
firewall-cmd --permanent --add-service=rpc-bind --zone=public
firewall-cmd --permanent --add-service=nfs      --zone=public
firewall-cmd --permanent --add-service=nfs3     --zone=public
firewall-cmd --permanent --add-service=mountd   --zone=public

firewall-cmd --reload
firewall-cmd --list-all
```

-----

## 4. NFS 공유 설정

### 4.1. 공유 디렉터리 생성 및 권한 설정

클라이언트와 공유할 디렉터리를 생성하고 적절한 권한을 부여합니다. 여기서는 예시로 `/data/exports` 디렉터리를 생성하고 모든 사용자가 읽고 쓸 수 있도록 `777` 권한을 설정합니다.

```bash
mkdir -p /data/exports

chmod -R 777 /data/exports
```

### 4.2. exports 파일 설정

`/etc/exports` 파일에 공유할 디렉터리와 접근 정책을 정의합니다.

  * `/data/exports`: 공유할 디렉터리 경로
  * `*`: 모든 클라이언트(`world`)에게 허용
  * `(rw,root_squash)`: 옵션
      * **`rw`**: 읽기/쓰기 권한을 허용합니다.
      * **`root_squash`**: 원격 클라이언트의 root 사용자를 서버의 `nfsnobody` 사용자로 매핑하여 보안을 강화합니다.

<!-- end list -->

```bash
cat <<EOF > /etc/exports
/data/exports *(rw,root_squash)
EOF
```

### 4.3. 설정 적용

`/etc/exports` 파일의 변경 내용을 시스템에 적용하기 위해 NFS 서버를 재시작합니다.

```bash
systemctl restart nfs-server.service
```

-----

## 5. 공유 상태 확인

`exportfs -v` 명령어를 사용하여 현재 NFS 서버에서 공유되고 있는 디렉터리와 적용된 옵션을 상세하게 확인할 수 있습니다.

```bash
exportfs -v
```

**실행 결과 예시:**

```logs
[root@thinkpad ~]# exportfs -v
/data/exports   <world>(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,root_squash,no_all_squash)
```