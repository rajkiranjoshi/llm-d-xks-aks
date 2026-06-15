`llm-d`-ready cluster creation for Azure Kubernetes Service (AKS)
===

Prerequisites
---

* GNU Make
* latest [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) binary with `aks-preview` extension installed
* `kubectl`
* `helm`


User management
---

The `user-mgmt.sh` script manages multi-tenant access to the cluster. Each user gets an isolated namespace, a ServiceAccount, and RBAC bindings:

```bash
# Add a user with the default llmd-user role
./user-mgmt.sh add alice

# Add a user with admin privileges
./user-mgmt.sh add bob --role admin

# List all users and their roles
./user-mgmt.sh list

# Temporarily revoke access (preserves namespace and resources)
./user-mgmt.sh suspend alice

# Restore access
./user-mgmt.sh resume alice

# Remove a user entirely
./user-mgmt.sh remove alice
```

Two ClusterRoles are provided in `rbac/`:

| Role | Description |
| ---- | ----------- |
| `llmd-user` | Standard user role with permissions to deploy llm-d workloads, manage CRDs (Gateway API, GAIE, LeaderWorkerSet), and use cluster-scoped RBAC within their namespace |
| `llmd-admin` | Full cluster-admin privileges |

User namespaces are labeled with `pod-security.kubernetes.io/enforce=privileged` to allow GPU and RDMA workloads that require `IPC_LOCK` capabilities and `hostPath` volumes.


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

After GPU Operator is deployed and running, the containerd NRI plugin is also deployed. By default, Azure Kubernetes Service sets a maximum locked memory limit of 64K per container, which is insufficient for vLLM's NIXL connector. To address this limitation, Node Resource Interface must be enabled on all GPU nodes. This script *must* run only after GPU Operator has completely finished deploying.

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

