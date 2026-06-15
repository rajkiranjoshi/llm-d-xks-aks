`llm-d`-ready cluster creation for Azure Kubernetes Service (AKS)
===

Prerequisites
---

* GNU Make
* latest [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) binary with `aks-preview` extension installed
* `kubectl`
* `helm`


Makefile structure
---

This repository contains a `Makefile` designed to facilitate AKS cluster creation compatible and prepared for `llm-d` deployment further down the line. While it has sane and usable defaults, there are a couple of variables used to tweak cluster creation and drivers deployment:

| Variable       | Default value | Meaning |
| -------------- | ------------- | ------- |
| `RESOURCE_GROUP` | `llmd-rg-1`      | Azure resrouce group name |
| `CLUSTER_NAME`   | `llmd-cluster-1` | AKS cluster name |
| `LOCATION`       | `eastus`         | Azure region/location |
| `CONTROL_SKU`    | `Standard_D5_v2` | Size of virtual machine used for running the control plane |
| `GPU_SKU`        | `Standard_NC24ads_A100_v4` | Size of virtual machine (with GPU!) used for running gpu worker nodes |
| `CONTROL_NODE_COUNT` | `2`          | How many control worker nodes to add |
| `NODE_COUNT`     | `1`              | How many GPU worker node to be added |
| `SSH_KEY_FILE`   | `${HOME}/.ssh/azure.pub` | Path to ssh public key used to access nodes via SSH |
| `GPU_OPERATOR_VERSION` | `v25.10.0` | GPU Operator version to deploy |
| `NODEPOOL_NAME`  | `gpunp`          | AKS nodepool name |
| `GPU_NODE_LABEL` | `sku=gpu`        | Label to add to all GPU nodes |
| `NRI_NAMESPACE`  | `kube-system`    | Namespace in which to deploy NRI plugin |
| `CLUSTER_TAGS`   | ` `              | Cluster tags to add to the AKS cluster. Multiple tags can be separated by space |
| `ENABLE_IB`      | ` `              | Turn this to "True" in order to enable InfiniBand support |
| `NETWORK_OPERATOR_VERSION` | `v26.1.0` | Nvidia Network Operator version deplyed for IB support |
| `NIC_POLICY`    | `rdma-shared-device-plugin` | What NicClusterPolicy to deploy when calling `deploy-nicpolicy` |
| `SYSTEM_NODEPOOL_NAME` | `systemnp` | Name of the AKS system nodepool |
| `CPU_NODEPOOL_NAME` | `cpunp`    | Name of the dedicated CPU worker nodepool |
| `CPU_SKU`        | `Standard_D5_v2` | VM size for CPU worker nodes |
| `CPU_NODE_COUNT` | `2`              | Number of CPU worker nodes |

In order to override any of the variables:

```bash
$ VARIABLE=value make target
```


Makefile targets
---

The Makefile provides a couple of generic targets:

| Target    | Description |
| --------  | ----------- |
| `check-deps` | Check if required binaries and utilities are available |
| `clean`   | Completely delete AKS cluster, this will remove all worker and control planes nodes and any configuration associated with it. Use with caution! |
| `cluster` | Create a new cluster from scratch and download kubeconfig |
| `deploy`  | Deploy GPU Operator to provide Nvidia drivers and NRI plugin on worker nodes |
| `register-ib-feature` | Register AKS InfiniBand support feature |
| `deploy-networkoperator` | Deploy Nvidia Network Operator |
| `deploy-nicpolicy` | Apply NicClusterPolicy for the network operator |
| `cluster-cpunodepool` | Create a dedicated CPU worker nodepool and taint the system nodepool |
| `cluster-delete-cpunp` | Delete the CPU worker nodepool |
| `deploy-monitoring` | Enable Azure Managed Prometheus metrics scraping |
| `help`    | Help with all the available make targets |


Cluster creation
---

```bash
# use defaults
make cluster

# personalize
RESOURCE_GROUP=rg_name CLUSTER_NAME=new_cluster_name NODE_COUNT=3 GPU_SKU=Standard_NC24ads_A100_v4 make cluster

# test
kubectl get node

```

This will create a new Azure resource group, a new AKS cluster and attach a new Node pool with GPUs. Please note the script *does not* deploy gpu drivers (by using `--gpu-driver none`). The access credentials are downloaded and added to the default `kubectl` context. You should be able to test the new deployment with a simple `kubectl get node`. The new AKS cluster is tagged with the Azure username used for creation and additionag tags can be added by using the `CLUSTER_TAGS` environment variable.

Cluster configuration
---

```bash
# use defaults
make deploy

# personalize
GPU_OPERATOR_VERSION=v25.10.0 NRI_NAMESPACE=kube-system make deploy
```

The `deploy` target handles the GPU drivers layer since the node pool was initialized with `--gpu-driver none` in the previous step. The script installs GPU Operator that in turn deploys needed NVidia drivers. This is handled via `helm`. Of note is the `--set "driver.rdma.enabled=true"` argument, which enables RDMA. This is harmless even if using a single node or no RDMA capable accelerators. The compilation and deplyoment of GPU Operator will take several minutes. It is best to watch the pods using `kubectl -n gpu-operator get pod` until all pods are in state "Running".

The GPU Operator is deployed with the following enhancements:

* **GPU node taints**: GPU nodes are tainted with `nvidia.com/gpu=present:NoSchedule` to prevent non-GPU workloads from being scheduled on them. The GPU Operator's DaemonSets are configured with matching tolerations.
* **IBGDA kernel module params**: A ConfigMap (`nvidia-kernel-module-params`) sets `NVreg_EnableStreamMemOPs=1` and `NVreg_RegistryDwords=PeerMappingOverride=1;` to enable InfiniBand GPU Direct Async for DeepEP/NVSHMEM workloads.
* **GDRCopy**: Enabled via `gdrcopy.enabled=true` for GPU Direct RDMA copy support, sometimes required by DeepEP/NVSHMEM IBGDA.
* **CPU worker nodepool**: A separate nodepool (`cluster-cpunodepool`) is provided for non-GPU workloads (e.g., routers, coordinators), and the system nodepool is tainted to reject non-system pods.

After GPU Operator is deployed and running, the containerd NRI plugin is also deployed. By default, Azure Kubernetes Service sets a maximum locked memory limit of 64K per container, which is insufficient for vLLM's NIXL connector. To address this limitation, Node Resource Interface must be enabled on all GPU nodes. This script *must* run only after GPU Operator has completely finished deploying.

### Cluster start/stop

The `aks-cluster-ctl.sh` script provides convenience commands to start, stop, and check the status of the AKS cluster for cost savings when not in use:

```bash
./aks-cluster-ctl.sh start
./aks-cluster-ctl.sh stop
./aks-cluster-ctl.sh status
```

Validation
---

After deplyoment, there are a couple of tests that can be used as validation:

1. Check GPU detection

```
kubectl describe nodes -l sku=gpu | grep -E "nvidia.com/gpu|rdma/ib"
```

Output should contain something like `nvidia.com/gpu: [number]` and `rmda/ib: [number]`.

2. Check GPU operator pods

```
kubectl get pods -n gpu-operator
kubectl get pods -n network-operator
```

All of the pods should be in state "Running".

3. Verify gateway ip

```
export GATEWAY_IP=$(kubectl get gateway -n "${LLMD_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')
echo "Gateway IP: ${GATEWAY_IP}"
```

4. Verify llmd pods

```
kubectl get pods -n "${LLMD_NAMESPACE}" -w
```

All the pods should be in "Running" state.

