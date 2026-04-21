#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [start|stop]}"
ACTION="${2:-}"
RESOURCE_GROUP="${AKS_RESOURCE_GRP:?Environment variable AKS_RESOURCE_GRP must be set}"

case "$ACTION" in
  start)
    echo "Starting AKS cluster '$CLUSTER_NAME' in resource group '$RESOURCE_GROUP'..."
    az aks start --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --no-wait
    echo "Start command issued (--no-wait). Use '$0 $CLUSTER_NAME status' to check status."
    ;;
  stop)
    echo "Stopping AKS cluster '$CLUSTER_NAME' in resource group '$RESOURCE_GROUP'..."
    az aks stop --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --no-wait
    echo "Stop command issued (--no-wait). Use '$0 $CLUSTER_NAME status' to check status."
    ;;
  status|"")
    az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
      --query "{name:name, powerState:powerState.code, provisioningState:provisioningState, kubernetesVersion:kubernetesVersion, location:location}" \
      --output table
    ;;
  *)
    echo "Error: unknown action '$ACTION'" >&2
    echo "Usage: $0 <cluster-name> [start|stop|status]" >&2
    exit 1
    ;;
esac
