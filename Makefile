RESOURCE_GROUP ?= llmd-rg-1
CLUSTER_NAME ?= llmd-cluster-1
LOCATION ?= eastus
CONTROL_SKU ?= Standard_D5_v2
GPU_SKU ?= Standard_NC4as_T4_v3
CONTROL_NODE_COUNT ?= 2
NODE_COUNT ?= 1
SSH_KEY_FILE ?= ${HOME}/.ssh/azure.pub
GPU_OPERATOR_VERSION ?= v25.10.0
NODEPOOL_NAME ?= gpunp
GPU_NODE_LABEL ?= sku=gpu
SYSTEM_NODEPOOL_NAME ?= systemnp
CPU_NODEPOOL_NAME ?= cpunp
CPU_SKU ?= Standard_D5_v2
CPU_NODE_COUNT ?= 2
NRI_NAMESPACE ?= kube-system
CLUSTER_TAGS ?= 

# InfiniBand / Network Operator
ENABLE_IB ?=
NETWORK_OPERATOR_VERSION ?= v26.1.0
NIC_POLICY ?= rdma-shared-device-plugin

ifdef ENABLE_IB
_NODEPOOL_IB_FLAGS = --os-sku Ubuntu
_GPU_OP_IB_FLAGS = --set "nfd.enabled=false"
endif

default: help

help:
	@echo "Usage:"
	@echo "   make <target>"
	@echo ""
	@echo "Cluster targets:"
	@echo "   check-deps             -- check if required binaries are available"
	@echo "   cluster                -- cluster-create, cluster-nodepool, and cluster-credentials"
	@echo "   cluster-create         -- create a new AKS cluster"
	@echo "   cluster-nodepool       -- create GPU nodepool (adds --os-sku Ubuntu if ENABLE_IB=true)"
	@echo "   cluster-cpunodepool    -- create CPU worker nodepool (CPU_SKU=$(CPU_SKU), CPU_NODE_COUNT=$(CPU_NODE_COUNT))"
	@echo "   cluster-credentials    -- download the cluster credentials (kubeconfig)"
	@echo "   cluster-delete-cpunp   -- delete CPU worker nodepool"
	@echo "   cluster-clean          -- completely delete created AKS cluster"
	@echo ""
	@echo "Deploy targets:"
	@echo "   deploy-gpuoperator     -- deploy Nvidia GPU Operator with IBGDA kernel params (adds nfd.enabled=false if ENABLE_IB=true)"
	@echo "   deploy-nri             -- deploy NRI ulimit-adjuster plugin (raises locked memory limits for GPU/RDMA pods)"
	@echo "   deploy-monitoring      -- enable Azure Managed Prometheus metrics scraping"
	@echo "   deploy-llmd-monitoring -- deploy llm-d Prometheus+Grafana stack with DOCA RDMA metrics"
	@echo ""
	@echo "InfiniBand targets (set ENABLE_IB=true):"
	@echo "   register-ib-feature    -- register AKS InfiniBand support feature"
	@echo "   deploy-networkoperator -- deploy Nvidia Network Operator + NFD rule"
	@echo "   deploy-nicpolicy       -- deploy NicClusterPolicy CR (NIC_POLICY=$(NIC_POLICY))"
	@echo "   verify-ib              -- check Network Operator and RDMA resource status"

check-deps:
	@which az
	@az extension list | grep -i preview
	@which kubectl
	@which helm

clean: cluster-clean
cluster: cluster-create cluster-nodepool cluster-credentials
deploy: deploy-gpuoperator deploy-nri

cluster-clean:
	@echo "Deleting Azure Resource Group ${RESOURCE_GROUP} in the background..."
	@echo "This will take 10-15 minutes to complete."
	az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
	@echo "Unregistering the ManagedGatewayAPIPreview feature..."
	az feature unregister --namespace "Microsoft.ContainerService" --name "ManagedGatewayAPIPreview"
	@echo "Cleaning up local kubeconfig entry..."
	kubectl config delete-cluster "${CLUSTER_NAME}"
	kubectl config delete-context "${CLUSTER_NAME}"
	@echo "Cleaning up local Helm repositories..."
	helm repo remove nvidia
	@echo "Cleanup initiated. The resource group ${RESOURCE_GROUP} is deleting in the background."

cluster-create:
	@echo "Creating Resource Group (skipping if it already exists)"
	az group show --name "${RESOURCE_GROUP}" > /dev/null 2>&1 || \
		az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
	@echo "Creating AKS Cluster (control plane)"
	az aks create --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --location "${LOCATION}" \
		--node-count "${CONTROL_NODE_COUNT}" --node-vm-size "${CONTROL_SKU}" --ssh-key-value "${SSH_KEY_FILE}" \
		--nodepool-name "${SYSTEM_NODEPOOL_NAME}" \
		--nodepool-labels "node-role.kubernetes.io/system=" \
		--tags "owner=$(shell az account show --query user.name -o tsv)" $(CLUSTER_TAGS:%=%)

cluster-nodepool:
	@echo "Adding GPU Node Pool"
	az aks nodepool add --resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
		--name "${NODEPOOL_NAME}" --node-count "${NODE_COUNT}" --node-vm-size "${GPU_SKU}" \
		--gpu-driver none --labels "${GPU_NODE_LABEL}" "node-role.kubernetes.io/gpu-worker=" \
		--node-taints "nvidia.com/gpu=present:NoSchedule" $(_NODEPOOL_IB_FLAGS)

cluster-cpunodepool:
	@echo "Adding CPU Worker Node Pool ($(CPU_NODEPOOL_NAME))"
	az aks nodepool add --resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
		--name "${CPU_NODEPOOL_NAME}" --node-count "${CPU_NODE_COUNT}" --node-vm-size "${CPU_SKU}" \
		--labels "node-role.kubernetes.io/cpu-worker="
	@echo "Tainting system nodepool ($(SYSTEM_NODEPOOL_NAME)) to reject non-system pods..."
	az aks nodepool update --resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
		--name "${SYSTEM_NODEPOOL_NAME}" --node-taints "CriticalAddonsOnly=true:NoSchedule"

cluster-delete-cpunp:
	@echo "Deleting CPU Worker Node Pool ($(CPU_NODEPOOL_NAME))..."
	az aks nodepool delete --resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
		--name "${CPU_NODEPOOL_NAME}" --no-wait
	@echo "Delete initiated (--no-wait). Check portal or 'az aks nodepool list' for progress."

cluster-credentials:
	@echo "Getting Cluster Credentials"
	az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing

register-ib-feature:
	@echo "Registering AKS InfiniBand Support feature..."
	az feature register --name AKSInfinibandSupport --namespace Microsoft.ContainerService
	@echo "Check status with:"
	@echo "  az feature show --namespace Microsoft.ContainerService --name AKSInfinibandSupport --query properties.state -o tsv"

deploy-networkoperator:
	@echo "Creating network-operator namespace with privileged pod security..."
	kubectl create ns network-operator --dry-run=client -o yaml | kubectl apply -f -
	kubectl label --overwrite ns network-operator pod-security.kubernetes.io/enforce=privileged
	@echo "Deploying NVIDIA Network Operator ${NETWORK_OPERATOR_VERSION}"
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update
	helm upgrade --install --create-namespace -n network-operator \
		network-operator nvidia/network-operator \
		-f ./network-operator/values.yaml \
		--version "${NETWORK_OPERATOR_VERSION}"
	@echo "Applying NodeFeatureRule for Mellanox NIC detection..."
	kubectl apply -f ./network-operator/nfd-rule.yaml

deploy-nicpolicy:
	@echo "Deploying NicClusterPolicy ($(NIC_POLICY))..."
	kubectl apply -f ./network-operator/nicclusterpolicy-$(NIC_POLICY).yaml
	@echo "MOFED driver installation will take 10-15 minutes. Run 'make verify-ib' to monitor."

verify-ib:
	@echo "=== Network Operator Pods ==="
	@kubectl -n network-operator get pods -o wide
	@echo ""
	@echo "=== NicClusterPolicy State ==="
	@kubectl get nicclusterpolicy nic-cluster-policy -o jsonpath='{.status.state}{"\n"}' 2>/dev/null || echo "Not found or no status yet"
	@echo ""
	@echo "=== Nodes with InfiniBand ==="
	@kubectl get nodes -l "feature.node.kubernetes.io/rdma-infiniband.capable=true" --no-headers 2>/dev/null || echo "No labeled nodes found yet"
	@echo ""
	@echo "=== RDMA Resources on Nodes ==="
	@kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): rdma/shared_ib=\(.status.allocatable["rdma/shared_ib"] // "N/A"), rdma/ib=\(.status.allocatable["rdma/ib"] // "N/A")"' 2>/dev/null || echo "Could not query RDMA resources"

deploy-gpuoperator:
	@echo "Deploying Nvidia GPU Operator ${GPU_OPERATOR_VERSION}"
	kubectl create ns gpu-operator --dry-run=client -o yaml | kubectl apply -f -
	kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged
	kubectl apply -f ./gpu-operator/nvidia-kernel-module-params.yaml
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update
	helm upgrade --install --wait -n gpu-operator --create-namespace \
		gpu-operator nvidia/gpu-operator \
		--version "${GPU_OPERATOR_VERSION}" \
		--set "driver.rdma.enabled=true" \
		--set "driver.kernelModuleConfig.name=nvidia-kernel-module-params" \
		--set "gdrcopy.enabled=true" \
		--set "daemonsets.tolerations[0].key=nvidia.com/gpu" \
		--set "daemonsets.tolerations[0].effect=NoSchedule" \
		--set "daemonsets.tolerations[0].operator=Exists" \
		--set "node.taints[0].key=nvidia.com/gpu" \
		--set "node.taints[0].effect=NoSchedule" \
		--set "node.taints[0].operator=Equal" \
		--set "node.taints[0].value=present" \
		$(_GPU_OP_IB_FLAGS)

deploy-nri:
	@echo "Deploying NRI ulimit-adjuster plugin"
	helm upgrade --install nri-setup ./nri-config/ --namespace "${NRI_NAMESPACE}" --create-namespace

deploy-monitoring:
	@echo "Enabling Azure Managed Prometheus metrics scraping"
	az aks update --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" \
		--enable-azure-monitor-metrics

deploy-llmd-monitoring:
	@echo "Deploying llm-d Prometheus + Grafana stack..."
	@if [ ! -d /tmp/llm-d-monitoring ]; then \
		git clone --depth 1 --filter=blob:none --sparse \
			https://github.com/llm-d/llm-d.git /tmp/llm-d-monitoring && \
		cd /tmp/llm-d-monitoring && git sparse-checkout set docs/monitoring; \
	fi
	cd /tmp/llm-d-monitoring/docs/monitoring && bash ./scripts/install-prometheus-grafana.sh --enable-tls
	@echo "Applying DOCA telemetry RDMA ServiceMonitor..."
	kubectl apply -f ./monitoring/doca-telemetry-rdma.yaml
	@echo "Loading DOCA RDMA Grafana dashboard..."
	kubectl create configmap llmd-doca-rdma-network \
		--from-file=doca-rdma-network-dashboard.json=./monitoring/doca-rdma-network-dashboard.json \
		-n llm-d-monitoring --dry-run=client -o yaml | \
		kubectl label --local -f - grafana_dashboard=1 -o yaml | \
		kubectl apply -f -
	@echo "llm-d monitoring deployed. DOCA RDMA metrics + dashboard ready."
