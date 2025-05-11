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
if [[ "$MONITORING_CONFIG" == "true" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Monitoring configuration is disabled. Skipping ConfigMap creation."

    cat << EOF | ./oc apply -f -
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
    enableUserWorkload: true                  
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    metricsServer:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    monitoringPlugin:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""                   
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
EOF

    ### Check if the ConfigMap is applied successfully
    if oc get configmap cluster-monitoring-config -n openshift-monitoring &> /dev/null; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] ConfigMap 'cluster-monitoring-config' is applied successfully."
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] ConfigMap 'cluster-monitoring-config' is not applied successfully. Exiting..."
    fi
else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Monitoring configuration is enabled. Skipping ConfigMap creation."
fi