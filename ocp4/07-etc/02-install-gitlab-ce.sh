
###
GITLAB_HOST_NAME="gitlab.hub.tistory.disconnected"
GITLAB_HOME="/opt/gitlab"

# Create directories for GitLab and SSL certificates
mkdir -p $GITLAB_HOME/config
mkdir -p $GITLAB_HOME/logs
mkdir -p $GITLAB_HOME/data
mkdir -p $GITLAB_HOME/ssl

# Place your certificate and key files in $SSL_CERT_DIR
# Example: cp /path/to/gitlab.example.com.crt $SSL_CERT_DIR/gitlab.example.com.crt
#          cp /path/to/gitlab.example.com.key $SSL_CERT_DIR/gitlab.example.com.key

cp /root/ocp4/support-system/custom-certs/domain_certs/$GITLAB_HOST_NAME.crt $GITLAB_HOME/ssl/$GITLAB_HOST_NAME.crt
cp /root/ocp4/support-system/custom-certs/domain_certs/$GITLAB_HOST_NAME.key $GITLAB_HOME/ssl/$GITLAB_HOST_NAME.key
chmod 600 $GITLAB_HOME/ssl/$GITLAB_HOST_NAME.*

podman run --detach \
  --hostname $GITLAB_HOST_NAME \
  --env GITLAB_OMNIBUS_CONFIG="\
    external_url 'https://$GITLAB_HOST_NAME'; \
    nginx['redirect_http_to_https'] = true; \
    nginx['ssl_certificate'] = '/etc/gitlab/ssl/$GITLAB_HOST_NAME.crt'; \
    nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/$GITLAB_HOST_NAME.key'; \
  " \
  --publish 7443:443 --publish 2222:22 \
  --name gitlab \
  --restart always \
  --volume $GITLAB_HOME/config:/etc/gitlab:Z \
  --volume $GITLAB_HOME/logs:/var/log/gitlab:Z \
  --volume $GITLAB_HOME/data:/var/opt/gitlab:Z \
  --volume $GITLAB_HOME/ssl:/etc/gitlab/ssl:Z \
  --shm-size 256m \
  docker.io/gitlab/gitlab-ce:latest

# Add SELinux port mappings
semanage port -a -t http_port_t -p tcp 7443
semanage port -a -t ssh_port_t -p tcp 2222

# Configure firewall
firewall-cmd --permanent --add-port=7443/tcp --add-port=2222/tcp --zone=public
firewall-cmd --reload




### 설치 포기 : minio 이미지 문제 해결 안 됨
### GitLab Operator를 위한 추가 이미지
###   oc-mirror로 전체 이미지가 포함 되지 않음. gitlab 인스턴스 생성 후 event 로그 확인하고 필요한 이미지를 추가로 pull/push 해야 함.
###

podman pull registry.gitlab.com/gitlab-org/build/cng/kubectl:v18.3.1
podman tag  registry.gitlab.com/gitlab-org/build/cng/kubectl:v18.3.1 registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/kubectl:v18.3.1
podman push registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/kubectl:v18.3.1 --tls-verify=false

podman pull registry.gitlab.com/gitlab-org/build/cng/cfssl-self-sign:v18.3.1
podman tag  registry.gitlab.com/gitlab-org/build/cng/cfssl-self-sign:v18.3.1 registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/cfssl-self-sign:v18.3.1
podman push registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/cfssl-self-sign:v18.3.1 --tls-verify=false


podman pull docker.io/bitnamilegacy/redis:7.2.4-debian-12-r9
podman tag  docker.io/bitnamilegacy/redis:7.2.4-debian-12-r9 registry.hub.tistory.disconnected:5000/bitnamilegacy/redis:7.2.4-debian-12-r9
podman push registry.hub.tistory.disconnected:5000/bitnamilegacy/redis:7.2.4-debian-12-r9 --tls-verify=false

podman pull docker.io/bitnamilegacy/postgresql:16.6.0
podman tag  docker.io/bitnamilegacy/postgresql:16.6.0 registry.hub.tistory.disconnected:5000/bitnamilegacy/postgresql:16.6.0
podman push registry.hub.tistory.disconnected:5000/bitnamilegacy/postgresql:16.6.0 --tls-verify=false

podman pull docker.io/minio/minio:RELEASE.2017-12-28T01-21-00Z
podman tag  docker.io/minio/minio:RELEASE.2017-12-28T01-21-00Z registry.hub.tistory.disconnected:5000/minio/minio:RELEASE.2017-12-28T01-21-00Z
podman push registry.hub.tistory.disconnected:5000/minio/minio:RELEASE.2017-12-28T01-21-00Z --tls-verify=false

podman pull docker.io/bitnamilegacy/redis-exporter:1.58.0-debian-12-r4
podman tag  docker.io/bitnamilegacy/redis-exporter:1.58.0-debian-12-r4 registry.hub.tistory.disconnected:5000/bitnamilegacy/redis-exporter:1.58.0-debian-12-r4
podman push registry.hub.tistory.disconnected:5000/bitnamilegacy/redis-exporter:1.58.0-debian-12-r4 --tls-verify=false

podman pull docker.io/bitnamilegacy/postgres-exporter:0.15.0-debian-11-r7
podman tag  docker.io/bitnamilegacy/postgres-exporter:0.15.0-debian-11-r7 registry.hub.tistory.disconnected:5000/bitnamilegacy/postgres-exporter:0.15.0-debian-11-r7
podman push registry.hub.tistory.disconnected:5000/bitnamilegacy/postgres-exporter:0.15.0-debian-11-r7 --tls-verify=false

podman pull registry.gitlab.com/gitlab-org/build/cng/certificates:v18.3.1
podman tag  registry.gitlab.com/gitlab-org/build/cng/certificates:v18.3.1 registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/certificates:v18.3.1
podman push registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/certificates:v18.3.1 --tls-verify=false

podman pull registry.gitlab.com/gitlab-org/build/cng/gitlab-base:v18.3.1
podman tag  registry.gitlab.com/gitlab-org/build/cng/gitlab-base:v18.3.1 registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/gitlab-base:v18.3.1
podman push registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/gitlab-base:v18.3.1 --tls-verify=false

podman pull registry.gitlab.com/gitlab-org/build/cng/gitaly:v18.3.1
podman tag  registry.gitlab.com/gitlab-org/build/cng/gitaly:v18.3.1 registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/gitaly:v18.3.1
podman push registry.hub.tistory.disconnected:5000/gitlab-org/build/cng/gitaly:v18.3.1 --tls-verify=false


### 추가 이미지에 대한 ImageTagMirrorSet 생성
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: add-images-for-operators
spec:
  imageTagMirrors:
  - mirrors:
    - registry.hub.tistory.disconnected:5000/gitlab-org
    source: registry.gitlab.com/gitlab-org
  - mirrors:
    - registry.hub.tistory.disconnected:5000/bitnamilegacy
    source: docker.io/bitnamilegacy
  - mirrors:
    - registry.hub.tistory.disconnected:5000/minio/minio
    source: minio/minio
EOF


mkdir -p /data/exports/ocp/gitlab/postgresql
mkdir -p /data/exports/ocp/gitlab/minio
mkdir -p /data/exports/ocp/gitlab/redis
mkdir -p /data/exports/ocp/gitlab/gitaly

chmod -R 777 /data/exports/ocp/gitlab

oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-gitlab-postgresql-0
  labels:
    storage: data-gitlab-postgresql-0
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 8Gi
  nfs:
    path: /data/exports/ocp/gitlab/postgresql
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitlab-minio
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 10Gi
  nfs:
    path: /data/exports/ocp/gitlab/minio
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-data-gitlab-redis-master-0
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 8Gi
  nfs:
    path: /data/exports/ocp/gitlab/redis
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: repo-data-gitlab-gitaly-0
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 50Gi
  nfs:
    path: /data/exports/ocp/gitlab/gitaly
    server: 11.119.120.28
  persistentVolumeReclaimPolicy: Retain

EOF

### 