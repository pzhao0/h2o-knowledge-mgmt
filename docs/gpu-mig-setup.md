# GPU and MIG cluster setup

Cluster administrators must complete this setup before [installing the application](../README.md#installation). Run the commands from the repository root. The application chart manages namespaced model-serving resources; the cluster administrator manages the NVIDIA operators, ClusterPolicy, and node configuration.

## Prerequisites

- An OpenShift worker with **one NVIDIA A100 80 GB** available for this workload. The agreed layout is two `2g.20gb` instances for H2O and one `3g.40gb` instance for OpenShift AI. These have approximately 20/20/40 GB dedicated GPU memory and 2/7, 2/7, and 3/7 of the MIG compute slices respectively. Sizes are nominal GPU profile names, not exact usable GiB. An A100 40 GB cannot provide this layout. See [NVIDIA's supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html).
- RHOAI with KServe enabled in Standard/RawDeployment mode, and a version whose InferenceService CRD supports `spec.predictor.deploymentStrategy`. Check this before deploying:
  ```bash
  oc explain inferenceservice.spec.predictor.deploymentStrategy
  ```
- Node Feature Discovery (NFD), including a NodeFeatureDiscovery instance, and NVIDIA GPU Operator, including a ready ClusterPolicy, working driver/device plugin, and MIG Manager. Follow the [NVIDIA OpenShift installation guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html) and [MIG setup guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mig-ocp.html). Use operator and driver versions compatible with your OpenShift release and the CUDA version in the configured vLLM image.
- Cluster administrator access for MIG setup; namespace deployment access for `make deploy`. The OpenShift AI predictor requests **4 CPUs, 32 GiB host RAM, and 60 GiB ephemeral storage**, with limits of 8 CPUs, 64 GiB host RAM, and 80 GiB ephemeral storage. Budget separately for both H2O workloads, the application, and platform overhead. Model cache is ephemeral and is downloaded again after pod replacement.

Record the OpenShift, RHOAI, GPU Operator, and driver versions used for validation. Discover the actual node, operator namespace, and ClusterPolicy rather than assuming the example names:

```bash
oc version
oc get csv -A
oc get clusterpolicies.nvidia.com
oc get nodes -L kubernetes.io/hostname,nvidia.com/gpu.product,nvidia.com/mig.capable

export MIG_NODE=<node-object-name>
export GPU_OPERATOR_NAMESPACE=nvidia-gpu-operator
export CLUSTER_POLICY=gpu-cluster-policy
# GPU_NODE is the hostname label used by the application's scheduler selector.
export GPU_NODE="$(oc get node "$MIG_NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')"

export DRIVER_POD="$(oc -n "$GPU_OPERATOR_NAMESPACE" get pods \
  -l app=nvidia-driver-daemonset --field-selector "spec.nodeName=$MIG_NODE" \
  -o jsonpath='{.items[0].metadata.name}')"
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- \
  nvidia-smi --query-gpu=index,name,memory.total,mig.mode.current --format=csv
```

Confirm that this lists exactly one A100 with approximately 80 GB memory. On nodes with preinstalled drivers, use the administrator's supported method to run `nvidia-smi` instead of a driver pod.

## Prepare for repartitioning

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

## Create and advertise the 20/20/40 layout

The administrator-owned [MIG configuration](../deploy/mig/a100-20-20-40.yaml) defines `h2o-20-20-rhoai-40` for GPU index 0: two `2g.20gb` instances and one `3g.40gb` instance. It also provides `all-disabled` for maintenance. This file is **not installed by the application Helm chart**.

Inspect `spec.migManager.config.name` in the ClusterPolicy first. If an existing custom ConfigMap is in use, merge the new profile into it and retain its other configurations; use that ConfigMap name below. Otherwise, install the supplied configuration:

```bash
oc -n "$GPU_OPERATOR_NAMESPACE" apply -f deploy/mig/a100-20-20-40.yaml
export MIG_CONFIGMAP=h2o-a100-mig-config
```

Use the `mixed` advertisement strategy so Kubernetes exposes distinct resource names for the 20 GB and 40 GB instances. After stopping all workloads on the GPU, configure MIG Manager and apply the profile:

```bash
oc patch clusterpolicy "$CLUSTER_POLICY" --type=merge \
  -p "{\"spec\":{\"mig\":{\"strategy\":\"mixed\"},\"migManager\":{\"enabled\":true,\"config\":{\"name\":\"$MIG_CONFIGMAP\"}}}}"

# Wait for the operator to reconcile and the ClusterPolicy to report ready.
oc get clusterpolicy "$CLUSTER_POLICY"

oc label node "$MIG_NODE" nvidia.com/mig.config=h2o-20-20-rhoai-40 --overwrite
oc wait --for=jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'=success \
  "node/$MIG_NODE" --timeout=20m
oc get node "$MIG_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config}{"\n"}{.metadata.labels.nvidia\.com/mig\.strategy}{"\n"}{.status.allocatable.nvidia\.com/mig-2g\.20gb}{"\n"}{.status.allocatable.nvidia\.com/mig-3g\.40gb}{"\n"}'
```

The final output must be `h2o-20-20-rhoai-40`, `mixed`, `2`, and `1`. Inspect the MIG Manager logs and device layout; reacquire the driver pod name because it may have restarted:

```bash
oc -n "$GPU_OPERATOR_NAMESPACE" logs ds/nvidia-mig-manager --all-containers --tail=100
export DRIVER_POD="$(oc -n "$GPU_OPERATOR_NAMESPACE" get pods \
  -l app=nvidia-driver-daemonset --field-selector "spec.nodeName=$MIG_NODE" \
  -o jsonpath='{.items[0].metadata.name}')"
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- nvidia-smi -L
oc -n "$GPU_OPERATOR_NAMESPACE" exec "$DRIVER_POD" -- nvidia-smi mig -lgi
```

Verify two `2g.20gb` instances and one `3g.40gb` instance on the same physical GPU. Do not proceed based only on an old `success` label: check the applied profile, strategy, device layout, and allocatable counts. Disable time slicing and MPS for these resources so each advertised device represents a dedicated MIG instance. Allocatable counts describe total capacity, not free capacity; inspect existing pod allocations and namespace quotas too.

## Use the two reserved 20 GB partitions for H2O

H2O owns its two model deployments and endpoints; this chart does not create placeholder pods or consume their GPU allocations. The two instances provide roughly 40 GB total, with **20 GB per model**. H2O must verify that its models and runtime overhead fit.

Configure each of the two H2O model pods through its owning chart/operator. For a Deployment, adapt these fields under `spec.template.spec`:

```yaml
nodeSelector:
  kubernetes.io/hostname: <same-GPU_NODE-hostname>
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
containers:
  - name: <h2o-model-container>
    image: <h2o-provided-image>
    resources:
      requests:
        nvidia.com/mig-2g.20gb: 1
      limits:
        nvidia.com/mig-2g.20gb: 1
```

Use one replica for each model and include H2O's CPU, RAM, storage, startup arguments, credentials, and any additional node tolerations. For KServe, put `nodeSelector` and `tolerations` under `spec.predictor`, the GPU requests/limits under `spec.predictor.model.resources`, and set the metadata annotation `serving.kserve.io/gpu-resource-types: '["nvidia.com/mig-2g.20gb"]'` on each InferenceService. Do not request `nvidia.com/gpu` or `nvidia.com/mig-3g.40gb`. The device plugin assigns a distinct 20 GB instance to each pod; do not hard-code MIG UUIDs. Use `Recreate` for Deployment updates (or `spec.predictor.deploymentStrategy.type: Recreate` for KServe) because a third 20 GB instance is unavailable.

Use a separate H2O namespace when the workloads have different owners. An administrator can cap that namespace with this ResourceQuota, applying it with `oc -n <h2o-namespace> apply -f <quota-file>`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: h2o-mig-budget
spec:
  hard:
    requests.nvidia.com/mig-2g.20gb: "2"
    requests.nvidia.com/mig-3g.40gb: "0"
    requests.nvidia.com/gpu: "0"
```

In the quickstart namespace, the corresponding caps are `requests.nvidia.com/mig-2g.20gb: "0"`, `requests.nvidia.com/mig-3g.40gb: "1"`, and `requests.nvidia.com/gpu: "0"`. These are optional administrator-managed quotas, not application chart resources. Quotas limit consumption; they do not reserve devices on a particular node. To enforce the ownership agreement, the administrator must also prevent other namespaces from requesting this node's MIG devices through namespace quotas/admission policy and appropriate node access controls. Until H2O deploys, both 20 GB instances remain unused and available to any otherwise eligible workload.

Confirm both H2O pods select the intended node, each sees a different `2g.20gb` MIG UUID, and the OpenShift AI predictor sees the `3g.40gb` UUID. Validate H2O inference independently and then concurrently with the OpenShift AI server. Repartitioning affects all three workloads and must be coordinated with both owners.

## Validate inference on the A100

After installing the application, wait for its model server to become ready:

```bash
export NAMESPACE=<my-namespace>
oc -n "$NAMESPACE" wait --for=condition=Ready inferenceservice/h2o-llm --timeout=30m
oc -n "$NAMESPACE" get pods -o wide
oc -n "$NAMESPACE" get deployment h2o-llm-predictor \
  -o custom-columns=NAME:.metadata.name,STRATEGY:.spec.strategy.type,REPLICAS:.spec.replicas
```

Confirm the predictor selects the prepared node, uses `Recreate` with one replica, and requests one `nvidia.com/mig-3g.40gb`. Run `nvidia-smi -L` inside the predictor and compare its visible MIG UUID with the administrator's listing. The two 20 GB allocations should remain unconsumed until H2O deploys its models.

Test ordinary inference through [the application's API docs](../README.md#try-a-model-request). This exercises the API-to-vLLM path without port forwarding. To validate tool calling, use a client with access to the internal vLLM endpoint: supply a tool definition, verify the returned structured call, execute it, and send the tool result back to obtain a final answer. `/ask` handles text prompts only.

After H2O deploys, run representative requests against all three workloads concurrently. During a subsequent OpenShift AI model update, verify the old predictor terminates before its replacement starts and H2O's endpoints remain available. Record startup duration, concurrent request latency, tool-call correctness, and GPU/host OOM errors before increasing context or concurrency. API tests and Helm lint do not establish model startup or memory fit on the A100.

If a predictor stays Pending, inspect events for node selection, taints, free MIG devices, host resources, and namespace quota. For startup failures, inspect predictor logs for download, driver/CUDA, quantization, and memory errors. Unused memory in H2O's partitions cannot be borrowed.

## Restore GPU configuration

To restore the previous GPU configuration, stop all GPU workloads first, restore the previous node MIG profile, and wait for MIG Manager success and the expected allocatable resources. Restore any changed ClusterPolicy fields only after coordinating with other GPU workloads. Use the saved configuration as a reference; do not reapply an entire saved Node object.
