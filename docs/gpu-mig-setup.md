# GPU and MIG cluster setup

Use this optional setup to run the two h2oGPTe GPU workloads on one NVIDIA RTX PRO 6000 Blackwell 96 GB GPU, split into two `2g.48gb` MIG instances. The default [Helm values template](../deploy/helm/values.5.2.1.yaml.tmp) uses two full GPUs instead.

Prepare the cluster and edit the values template **before running `make deploy`**. Cluster administrators manage the MIG layout; the installation script does not change GPU Operator settings. Run the commands below from the repository root.

| Workload | GPU allocation |
| --- | --- |
| h2oGPTe models service | One `nvidia.com/mig-2g.48gb` instance |
| h2oGPT function service | One `nvidia.com/mig-2g.48gb` instance |
| Chat LLM | Separate GPU capacity on OpenShift AI, or an external OpenAI-compatible endpoint |

Both MIG instances are used by h2oGPTe. They do not provide capacity for the separate chat LLM. Follow [Connect a model](../README.md#connect-a-model) after installation.

## Prerequisites

- One NVIDIA RTX PRO 6000 Blackwell 96 GB, preferably Server Edition, with **two `2g.48gb` MIG instances**. One is for the H2O model pod and one for the H2O function pod. Each receives half of the GPU's MIG SM capacity and nominal memory. Profile sizes are not exact usable GiB. See [NVIDIA's supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html#rtx-pro-6000-blackwell-mig-profiles).
- Node Feature Discovery and NVIDIA GPU Operator with a ready ClusterPolicy, working driver/device plugin, and MIG Manager supporting this GPU. Follow the [OpenShift installation guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html) and [MIG setup guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mig-ocp.html). Match operator/driver versions to your OpenShift release and H2O's CUDA runtimes. NVIDIA lists R575 (>= 575.51.03) as the minimum for RTX PRO Blackwell MIG; the selected platform or workloads may require newer versions. Workstation and Max-Q editions also require supported vBIOS and compute display mode; see [RTX PRO prerequisites](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/getting-started-with-mig.html#additional-prerequisites-for-rtx-pro-blackwell-gpus).
- H2O-provided model and function containers compatible with Blackwell SM120. Budget host CPU, RAM, and storage according to H2O's requirements, plus platform overhead. Confirm each workload fits its own 48 GB partition, including runtime overhead. A MIG partition provides half the physical GPU's compute capacity; it is not equivalent to a full GPU in throughput.
- Cluster administrator access for MIG setup and h2oGPTe installation. OpenShift AI/KServe is needed only if you also deploy the chat LLM on the cluster; h2oGPTe itself is installed by the H2O AI Cloud Helm chart. See the [quickstart requirements](../README.md#requirements).

Record the OpenShift, GPU Operator, driver, and H2O runtime versions. Discover the actual node, operator namespace, and ClusterPolicy:

```bash
oc version
oc get csv -A
oc get clusterpolicies.nvidia.com
oc get nodes -L kubernetes.io/hostname,nvidia.com/gpu.product,nvidia.com/mig.capable

export MIG_NODE=<node-object-name>
export GPU_OPERATOR_NAMESPACE=nvidia-gpu-operator
export CLUSTER_POLICY=gpu-cluster-policy
# Hostname label to check when verifying workload placement.
export GPU_NODE="$(oc get node "$MIG_NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')"
export DRIVER_POD="$(oc -n "$GPU_OPERATOR_NAMESPACE" get pods \
  -l app=nvidia-driver-daemonset --field-selector "spec.nodeName=$MIG_NODE" \
  -o jsonpath='{.items[0].metadata.name}')"
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- \
  nvidia-smi --query-gpu=index,name,memory.total,mig.mode.current --format=csv
```

Confirm that GPU index 0 is the intended RTX PRO 6000 Blackwell with approximately 96 GB memory. Adjust the supplied configuration if the intended GPU has another index. With preinstalled drivers, use the administrator's supported method to run `nvidia-smi` instead of a driver pod.

## Prepare the GPU for MIG setup

Save the current ClusterPolicy and node labels for reference:

```bash
oc get clusterpolicy "$CLUSTER_POLICY" -o yaml > gpu-cluster-policy-before-mig.yaml
oc get node "$MIG_NODE" -o yaml > gpu-node-before-mig.yaml
```

During a maintenance window, stop workloads using this GPU through their owning deployment or release. Check for remaining GPU workloads:

```bash
oc get pods -A --field-selector "spec.nodeName=$MIG_NODE" -o wide
```

The GPU must be free of user workloads before changing MIG mode or geometry. MIG Manager restarts GPU components, and some platforms require a GPU reset or node reboot. If your platform requires cordoning, draining, or enabling MIG Manager's `WITH_REBOOT` setting, follow its maintenance procedure and uncordon the node afterward. Changing the ClusterPolicy advertisement strategy also affects other GPU nodes in the cluster; coordinate this with their owners.

## Create and advertise the 48/48 layout

The administrator-owned [MIG configuration](../deploy/mig/rtx-pro-6000-48-48.yaml) defines `h2o-48-48` for GPU index 0: two `2g.48gb` instances. It also supplies `all-disabled` for maintenance. The installation script does not apply this file.

Inspect `spec.migManager.config.name` in the ClusterPolicy. If a custom ConfigMap is already used, merge this profile into it and retain its other configurations, using that ConfigMap's name below. Otherwise:

```bash
oc -n "$GPU_OPERATOR_NAMESPACE" apply -f deploy/mig/rtx-pro-6000-48-48.yaml
export MIG_CONFIGMAP=h2o-rtx-pro-6000-mig-config
```

Use the `mixed` advertisement strategy to expose the explicit resource name `nvidia.com/mig-2g.48gb`. After stopping all workloads on the GPU:

```bash
oc patch clusterpolicy "$CLUSTER_POLICY" --type=merge \
  -p "{\"spec\":{\"mig\":{\"strategy\":\"mixed\"},\"migManager\":{\"enabled\":true,\"config\":{\"name\":\"$MIG_CONFIGMAP\"}}}}"

# Wait for the operator to reconcile and the ClusterPolicy to report ready.
oc get clusterpolicy "$CLUSTER_POLICY"
oc label node "$MIG_NODE" nvidia.com/mig.config=h2o-48-48 --overwrite
oc wait --for=jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'=success \
  "node/$MIG_NODE" --timeout=20m
oc get node "$MIG_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config}{"\n"}{.metadata.labels.nvidia\.com/mig\.strategy}{"\n"}{.status.allocatable.nvidia\.com/mig-2g\.48gb}{"\n"}'
```

The final output must be `h2o-48-48`, `mixed`, and `2`. Inspect MIG Manager logs and the actual layout; reacquire the driver pod name after any restart:

```bash
oc -n "$GPU_OPERATOR_NAMESPACE" logs ds/nvidia-mig-manager --all-containers --tail=100
export DRIVER_POD="$(oc -n "$GPU_OPERATOR_NAMESPACE" get pods \
  -l app=nvidia-driver-daemonset --field-selector "spec.nodeName=$MIG_NODE" \
  -o jsonpath='{.items[0].metadata.name}')"
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- nvidia-smi -L
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- nvidia-smi mig -lgi
```

Verify exactly two `2g.48gb` instances on the same physical GPU. Confirm the actual layout as well as the `success` label. Disable time slicing and MPS for these resources so each advertised device represents a dedicated MIG instance. Allocatable counts describe total capacity, not free capacity; check pod allocations and namespace quotas as well.

## Configure the h2oGPTe Helm values

Edit `deploy/helm/values.<H2O_CHART_VERSION>.yaml.tmp`, matching the chart version in `.env` (currently `5.2.1`). Change the two existing `gpuResourceName` values from `nvidia.com/gpu` to `nvidia.com/mig-2g.48gb`:

```yaml
h2ogpte:
  config:
    models:
      resources:
        gpuResourceName: nvidia.com/mig-2g.48gb

h2ogpt:
  config:
    function:
      resources:
        gpuResourceName: nvidia.com/mig-2g.48gb
```

These are excerpts: edit the existing keys and keep the rest of the template, including the license, scheduling profiles, and CPU/memory settings. Do not append duplicate `h2ogpte` or `h2ogpt` mappings. Keep the GPU-node toleration under `global.profiles.h2ogpte-gpu-deployment`, adapting it if your node uses a different taint.

Edit the **versioned template**, not `deploy/helm/values.yaml`: the installer regenerates `values.yaml` on every run. Then follow [Configure the installation](../README.md#configure-the-installation) and run:

```bash
make deploy
```

The chart must request one MIG instance for each of the models and function workloads. Keep one replica of each. On a cluster with multiple nodes advertising `nvidia.com/mig-2g.48gb`, use the chart version's supported node-selection settings to constrain both workloads to the intended GPU node, and verify their rendered pod specifications. Do not pin device UUIDs: the device plugin assigns a different instance to each pod. Each pod has its own nominal 48 GB allocation; unused memory cannot be borrowed by the other pod.

There is no third MIG instance for an upgrade surge. Before upgrading these workloads, configure a chart-supported replacement strategy that releases the old pod's device before starting its replacement. Inspect the chart's rendered Deployment strategies and confirm this behavior during validation.

An administrator can optionally cap GPU consumption in the h2oGPTe namespace with this ResourceQuota (apply it to the namespace configured in `.env`):

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: h2o-mig-budget
spec:
  hard:
    requests.nvidia.com/mig-2g.48gb: "2"
    requests.nvidia.com/gpu: "0"
```

Keep a locally served chat LLM in a separate project, such as `h2o-llm`, with its own GPU capacity. Quotas cap consumption; they do not reserve devices. Prevent unrelated workloads from consuming the two H2O instances through administrator-managed quotas, admission policies, and node access controls.

## Validate h2oGPTe workloads

Set the namespace to the same value as `NAMESPACE` in `.env`:

```bash
export NAMESPACE=h2o-knowledge-mgmt
oc get pods -n "$NAMESPACE" -o wide
helm get manifest h2oai -n "$NAMESPACE"
oc get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}{.name}{" requests="}{.resources.requests}{" limits="}{.resources.limits}{"\n"}{end}{end}'
```

Confirm the models and function pods are on the intended node and each requests and limits exactly one `nvidia.com/mig-2g.48gb`, with no full-GPU request. Check their assigned MIG devices using the administrator's supported GPU monitoring tools and confirm different MIG UUIDs. Inspect logs for Blackwell kernel incompatibilities or GPU/host out-of-memory errors. Check memory use with both workloads running concurrently.

Complete [Verify and log in](../README.md#verify-and-log-in), [Connect a model](../README.md#connect-a-model), and [Load the sample documents](../README.md#load-the-sample-documents). Ask a question and check its citations. Also confirm that updating a GPU workload releases its existing device before requesting a replacement. Script syntax checks cannot establish GPU memory fit or real inference behavior.

## Troubleshooting

- **`Insufficient nvidia.com/mig-2g.48gb`:** check that the node advertises two instances and both are free, and that namespace quotas allow their use. Allocatable capacity is not the same as free capacity.
- **Pods still request `nvidia.com/gpu`:** edit both resource names in the template for the chart version in `.env`, then rerun `make deploy`. Editing the generated `values.yaml` does not persist.
- **Pods remain pending during an upgrade:** check whether old replicas still hold both instances. Use the chart's supported replacement strategy to avoid an extra GPU request.
- **MIG Manager reports an error:** inspect its logs and verify GPU/driver support and that no workload still holds the GPU before reconfiguration.

## Restore GPU configuration

To restore the previous GPU configuration, stop all GPU workloads first, restore the previous node MIG profile, and wait for MIG Manager success and the expected allocatable resources. Restore any changed ClusterPolicy fields only after coordinating with other GPU workloads. Use the saved configuration as a reference; do not reapply an entire saved Node object.

`make undeploy` removes h2oGPTe and its namespace, but leaves the administrator-managed MIG ConfigMap, node labels, GPU Operator, and ClusterPolicy in place. Restore those separately if the GPU is being returned to another use.
