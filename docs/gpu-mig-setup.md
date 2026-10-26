# GPU and MIG cluster setup

Cluster administrators prepare the GPU for H2O independently of the application Helm chart. Chat inference uses an external OpenAI-compatible endpoint.

## Prerequisites

- One NVIDIA RTX PRO 6000 Blackwell 96 GB, preferably Server Edition, with **two `2g.48gb` MIG instances**. One is for the H2O model pod and one for the H2O function pod. Each receives half of the GPU's MIG SM capacity and nominal memory. Profile sizes are not exact usable GiB. See [NVIDIA's supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html#rtx-pro-6000-blackwell-mig-profiles).
- Node Feature Discovery and NVIDIA GPU Operator with a ready ClusterPolicy, working driver/device plugin, and MIG Manager supporting this GPU. Follow the [OpenShift installation guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html) and [MIG setup guide](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mig-ocp.html). Match operator/driver versions to your OpenShift release and H2O's CUDA runtimes. NVIDIA lists R575 (>= 575.51.03) as the minimum for RTX PRO Blackwell MIG; the selected platform or workloads may require newer versions. Workstation and Max-Q editions also require supported vBIOS and compute display mode; see [RTX PRO prerequisites](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/getting-started-with-mig.html#additional-prerequisites-for-rtx-pro-blackwell-gpus).
- H2O-provided model and function containers compatible with Blackwell SM120. Budget host CPU, RAM, and storage according to H2O's requirements, plus application/platform overhead. Confirm each workload fits its own 48 GB partition, including runtime overhead. A MIG partition provides half the physical GPU's compute capacity; it is not equivalent to a full GPU in throughput.
- Cluster administrator access for MIG setup. This application's chart requires neither GPU access nor KServe resources. If H2O deploys through OpenShift AI/KServe, its owners must satisfy those platform prerequisites separately.

Record the OpenShift, GPU Operator, driver, and H2O runtime versions. Discover the actual node, operator namespace, and ClusterPolicy:

```bash
oc version
oc get csv -A
oc get clusterpolicies.nvidia.com
oc get nodes -L kubernetes.io/hostname,nvidia.com/gpu.product,nvidia.com/mig.capable

export MIG_NODE=<node-object-name>
export GPU_OPERATOR_NAMESPACE=nvidia-gpu-operator
export CLUSTER_POLICY=gpu-cluster-policy
# Hostname label used by H2O's workload scheduler selectors.
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

The administrator-owned [MIG configuration](../deploy/mig/rtx-pro-6000-48-48.yaml) defines `h2o-48-48` for GPU index 0: two `2g.48gb` instances. It also supplies `all-disabled` for maintenance. The application Helm chart does not install this file.

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

## Allocate both 48 GB partitions to H2O

H2O owns both deployments and endpoints. Configure the model pod and function pod through their owning chart/operator, with one instance per pod. The application does not create placeholders or reserve devices by consuming them.

For each Deployment, adapt the following under `spec.template.spec`:

```yaml
nodeSelector:
  kubernetes.io/hostname: <same-GPU_NODE-hostname>
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
containers:
  - name: <h2o-model-or-function-container>
    image: <h2o-provided-image>
    resources:
      requests:
        nvidia.com/mig-2g.48gb: 1
      limits:
        nvidia.com/mig-2g.48gb: 1
```

Use one replica per workload and include H2O's CPU, RAM, storage, startup arguments, credentials, and any additional tolerations. The device plugin assigns different MIG UUIDs; do not hard-code them. Each pod has its own 48 GB allocation, and unused memory cannot be borrowed by the other pod. Use `Recreate` updates because a third partition is unavailable.

If H2O uses KServe, put node selection and tolerations under `spec.predictor`, GPU requests/limits under `spec.predictor.model.resources`, and add `serving.kserve.io/gpu-resource-types: '["nvidia.com/mig-2g.48gb"]'` to the InferenceService metadata. Its platform must support an update strategy that avoids requiring a third partition, such as `spec.predictor.deploymentStrategy.type: Recreate`.

An administrator can cap the H2O namespace with this quota:

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

For a separate application namespace, cap both resource requests at `"0"`. If H2O and the application share a namespace, use the H2O quota and enforce ownership through appropriate admission policies. Quotas cap consumption; they do not reserve specific devices. Prevent unrelated namespaces from consuming this GPU through quotas/admission policy and node access controls. These policies are administrator-managed, not application chart resources.

## Validate H2O workloads

Confirm both pods select the intended node, request one `nvidia.com/mig-2g.48gb` each, and see different MIG UUIDs. Verify Blackwell kernel compatibility, model startup, and host/GPU memory usage independently and with both workloads running concurrently. Test each H2O endpoint, and confirm updates replace one pod without needing another MIG device.

Validate the application's text request against the [external endpoint](../README.md#try-a-model-request) while H2O is running. Confirm no application resources request a GPU. Record startup durations, concurrent request latency, and GPU/host OOM errors. Local tests and Helm lint cannot establish H2O memory fit or real inference behavior.

## Restore GPU configuration

To restore the previous GPU configuration, stop all GPU workloads first, restore the previous node MIG profile, and wait for MIG Manager success and the expected allocatable resources. Restore any changed ClusterPolicy fields only after coordinating with other GPU workloads. Use the saved configuration as a reference; do not reapply an entire saved Node object.
