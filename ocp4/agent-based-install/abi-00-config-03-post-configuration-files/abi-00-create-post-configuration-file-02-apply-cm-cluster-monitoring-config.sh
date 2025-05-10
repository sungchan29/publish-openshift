#!/bin/bash

# Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/../abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    alertmanagerMain:
      nodeSelector:
         node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
      volumeClaimTemplate:
        metadata:
          name: alertmanager-main-db
        spec:
          resources:
            requests:
              storage: 10Gi
    enableUserWorkload: false                  
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    metricsServer:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    monitoringPlugin:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists            
      volumeClaimTemplate:
        metadata:
          name: prometheus-k8s-db
        spec:
          resources:
            scrapeInterval: 1m
            retention: 24h
            retentionSize: 90GB
            requests:
              storage: 90Gi            
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
EOF

### Check if the ConfigMap is applied successfully
if oc get configmap cluster-monitoring-config -n openshift-monitoring &> /dev/null; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ConfigMap 'cluster-monitoring-config' is applied successfully."
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] ConfigMap 'cluster-monitoring-config' is not applied successfully. Exiting..."
fi