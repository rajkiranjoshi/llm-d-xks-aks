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
NRI_NAMESPACE ?= kube-system
CLUSTER_TAGS ?= 

default: help

help:
	@echo "Usage:"
	@echo "   make <target>"
	@echo "Available targets"
	@echo "   check-deps          -- check if required binaries are available"
	@echo "   clean               -- alias to cluster-clear"
	@echo "   cluster-clean       -- completely delete created AKS cluster"
	@echo "   cluster             -- cluster-create and cluster-credentials"
	@echo "   cluster-create      -- create a new AKS cluster "
	@echo "   cluster-nodepool    -- create and attach the desired GPU nodes as a nodepool"
	@echo "   cluster-credentials -- download the cluster credentials (kubeconfig)"
	@echo "   deploy              -- deploy GPU Operator and NRI plugin"
	@echo "   deploy-gpuoperator  -- deploy Nvidia GPU Operator using helmchart"
	@echo "   deploy-nriconfig    -- deploy NRI containerd plugin using helmchart"

check-deps:
	@which az
	@az extension list | grep -i preview
	@which kubectl
	@which helm

clean: cluster-clean
cluster: cluster-create cluster-nodepool cluster-credentials
deploy: deploy-gpuoperator deploy-nriconfig

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
	@echo "Creating Resource Group"
	az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
	@echo "Creating AKS Cluster (control plane)"
	az aks create --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --node-count "${CONTROL_NODE_COUNT}" \
		--node-vm-size "${CONTROL_SKU}" --ssh-key-value "${SSH_KEY_FILE}" \
		--tags "owner=$(shell az account show --query user.name -o tsv)" $(CLUSTER_TAGS:%=%)

cluster-nodepool:
	@echo "Adding GPU Node Pool"
	az aks nodepool add --resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" \
		--name "${NODEPOOL_NAME}" --node-count "${NODE_COUNT}" --node-vm-size "${GPU_SKU}" \
		--gpu-driver none --labels "${GPU_NODE_LABEL}"

cluster-credentials:
	@echo "Getting Cluster Credentials"
	az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing

deploy-gpuoperator:
	@echo "Deploying Nvidia GPU Operator"
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update
	helm install --wait -n gpu-operator --create-namespace \
		gpu-operator nvidia/gpu-operator \
		--version "${GPU_OPERATOR_VERSION}" \
		--set "driver.rdma.enabled=true"

deploy-nriconfig:
	@echo "Deploying NRI plugin"
	helm upgrade --install nri-setup ./nri-config/ --namespace "${NRI_NAMESPACE}" --create-namespace
