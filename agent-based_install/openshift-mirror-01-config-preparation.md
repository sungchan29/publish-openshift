###


```bash

mkdir -p ~/Downloads/ocp/mirror_workspace
cd ~/Downloads/ocp/mirror_workspace

```

```bash

vi openshift-mirror-01-config-preparation.sh

```

```bash
#!/bin/bash

#OCP_UPDATE_PATH="4.13.37"
#OCP_UPDATE_PATH="4.13.37--4.15.35"
#OCP_UPDATE_PATH="4.13.37--4.15.35--eus-4.16.16"
#OCP_UPDATE_PATH="4.16.7"
OCP_UPDATE_PATH="4.16.7--4.16.19--4.17.3"

DOWNLOAD_DIRECTORY="ocp4-install-files-v${OCP_UPDATE_PATH}"

OPENSHIFT_CLIENT_RHEL8_FILE="openshift-client-linux-amd64-rhel8.tar.gz"
OPENSHIFT_CLIENT_RHEL9_FILE="openshift-client-linux-amd64-rhel9.tar.gz"

OPENSHIFT_INSTALL_FILE="openshift-install-linux.tar.gz"
#OPENSHIFT_INSTALL_RHEL9_FILE="openshift-install-rhel9-amd64.tar.gz"

OC_MIRROR_RHEL8_FILE="oc-mirror.tar.gz"
OC_MIRROR_RHEL9_FILE="oc-mirror.rhel9.tar.gz"

### ocp graph-data
create_dockerfile() {
cat << EOF > ./Dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN curl -L -o cincinnati-graph-data.tar.gz https://api.openshift.com/api/upgrades_info/graph-data
RUN mkdir -p /var/lib/cincinnati-graph-data && tar xvzf cincinnati-graph-data.tar.gz -C /var/lib/cincinnati-graph-data/ --no-overwrite-dir --no-same-owner
CMD ["/bin/bash", "-c" ,"exec cp -rp /var/lib/cincinnati-graph-data/* /var/lib/cincinnati/graph-data"]
EOF
}

### Event Router
EVENTROUTER_IMAGE="registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4"

### Suppoert Tools
SUPPORT_TOOLS_IMAGE="registry.redhat.io/rhel9/support-tools:latest"

### OLM operators: redhat, certified, community
#OLM_OPERATORS="redhat"
#OLM_OPERATORS="redhat--certified"
#OLM_OPERATORS="redhat--community"
OLM_OPERATORS="redhat--certified--community"

SELECT_REDHAT_OPERATORS="\
advanced-cluster-management\
|cincinnati-operator\
|cluster-logging\
|cluster-observability-operator\
|compliance-operator\
|devworkspace-operator\
|file-integrity-operator\
|gatekeeper-operator-product\
|jaeger-product\
|kiali-ossm\
|kubernetes-nmstate-operator\
|local-storage-operator\
|lvms-operator\
|metallb-operator\
|multicluster-engine\
|netobserv-operator\
|node-healthcheck-operator\
|node-maintenance-operator\
|node-observability-operator\
|openshift-cert-manager-operator\
|openshift-custom-metrics-autoscaler-operator\
|openshift-gitops-operator\
|opentelemetry-product\
|redhat-oadp-operator\
|rhbk-operator\
|rhtas-operator\
|security-profiles-operator\
|self-node-remediation\
|servicemeshoperator\
|tempo-product\
|vertical-pod-autoscaler\
|volsync-product\
|web-terminal\
"
#|cephcsi-operator\
#|container-security-operator\
#|fence-agents-remediation\
#|mcg-operator\
#|ocs-client-operator\
#|ocs-operator\
#|odf-csi-addons-operator\
#|odf-multicluster-orchestrator\
#|odf-operator\
#|odf-prometheus-operator\
#|quay-bridge-operator\
#|quay-operator\
#|rhacs-operator\
#|rook-ceph-operator\
#|serverless-operator\
#
#|SR-IOV|numaresources
#|Virtualization

SELECT_CERTIFIED_OPERATORS="\
nginx-ingress-operator\
"

SELECT_COMMUNITY_OPERATORS="\
gitlab-operator-kubernetes\
"

OCP4_IMAGESET_CONFIG_FILE="ocp4-imageset-config.yaml"

OCP4_OLM_RH_IMAGESET_CONFIG_FILE="ocp4-olm-redhat-imageset-config.yaml"
OCP4_OLM_CT_IMAGESET_CONFIG_FILE="ocp4-olm-certified-imageset-config.yaml"
OCP4_OLM_CM_IMAGESET_CONFIG_FILE="ocp4-olm-community-imageset-config.yaml"

OC_MIRROR_HISTORY="oc-mirror_history.log"
```