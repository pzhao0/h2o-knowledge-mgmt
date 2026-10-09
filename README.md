# H2O Knowledge Management

> **WORK IN PROGRESS - NOT READY FOR USE**

This repository is an early scaffold for an AI Quickstart exploring knowledge management with H2O.ai and Red Hat OpenShift AI.

It currently contains a small Python API scaffold deployed with Helm alongside S3-compatible storage and RHOAI-managed vLLM inference. On install, a Job uploads the configured sample document to the `documents` bucket. The API currently provides a health endpoint at `/healthz`.

## Repository layout

```text
services/api/                    Python API, tests, and its uv.lock
services/document-uploader/      Sample upload job and its uv.lock
deploy/helm/h2o-knowledge-mgmt/  Helm chart for the API, S3 storage, document upload, and inference
```

## Installation

```bash
make deploy STORAGE_ACCESS_KEY_ID=my-access-key STORAGE_SECRET_ACCESS_KEY=my-secret-key
```

This uses the namespace from the current Kubernetes context. To deploy to a specific namespace (created if needed):

```bash
make deploy NAMESPACE=my-namespace STORAGE_ACCESS_KEY_ID=my-access-key STORAGE_SECRET_ACCESS_KEY=my-secret-key
```

## Project teardown

Remove the deployment from the current namespace, or specify the namespace used during installation:

```bash
make undeploy
make undeploy NAMESPACE=my-namespace
```

## Make targets


| Target           | Purpose                                                              |
| ---------------- | -------------------------------------------------------------------- |
| `make setup`     | Install Python and development dependencies.                         |
| `make test`      | Run API tests.                                                       |
| `make lint`      | Check Python code style.                                             |
| `make dev`       | Run the API locally.                                                 |
| `make helm-lint` | Check the Helm chart.                                                |
| `make helm-dependency-build` | Build dependencies from the checked-in `Chart.lock`.                  |
| `make helm-dependency-update` | Update dependency versions and the checked-in `Chart.lock`.           |
| `make deploy`    | Install the API, S3 storage, document upload, and vLLM inference. |
| `make undeploy`  | Remove the deployment.                                               |

Set `STORAGE_ACCESS_KEY_ID` and `STORAGE_SECRET_ACCESS_KEY` when deploying. The chart rejects empty storage credentials.


## vLLM inference

The pinned `llm-service` chart (`0.5.13`) creates a KServe `ServingRuntime`, an `InferenceService`, and an internal Service. RHOAI/KServe manages the inference workload. RHOAI with KServe and an available NVIDIA GPU must already be configured on the cluster.

Inference is enabled by default in `values.yaml`, serving [RedHatAI/Llama-3.2-3B-Instruct-quantized.w8a8](https://huggingface.co/RedHatAI/Llama-3.2-3B-Instruct-quantized.w8a8). The normal installation commands above include inference. To deploy without it:

```bash
make deploy NAMESPACE=my-namespace \
  STORAGE_ACCESS_KEY_ID=my-access-key STORAGE_SECRET_ACCESS_KEY=my-secret-key \
  HELM_ARGS='--set llm-service.enabled=false'
```

Inference requests one GPU, 1 CPU, 16Gi RAM, and 20Gi ephemeral storage; host-memory and storage limits are 32Gi and 30Gi. It uses the chart's default NVIDIA image, `vllm/vllm-openai:v0.11.1`, and a pinned Hugging Face model revision. The public model requires no Hugging Face token. The volume override removes an unused chat-template ConfigMap dependency that can disappear during chart upgrades.

The 3B model uses INT8 weights and activations, supported directly on Ampere GPUs such as A10G. The profile limits context to 2,048 tokens and concurrency to four sequences, with a 75% GPU-memory budget. See [vLLM INT8 hardware support](https://docs.vllm.ai/en/v0.11.1/features/quantization/int8/).

The image and toleration are explicitly set under `llm-service.deviceConfigs.gpu` in `values.yaml`, matching the pinned chart defaults. The default toleration is `nvidia.com/gpu:NoSchedule` with `operator: Exists`. For pools with custom taints, pass `GPU_TOLERATIONS` as a JSON array to `make deploy`. For example, with storage credentials already exported, the test cluster's A10G pool requires:

```bash
make deploy NAMESPACE=my-namespace \
  GPU_TOLERATIONS='[{"key":"g5-gpu","operator":"Equal","value":"true","effect":"NoSchedule"}]'
```

Or export it as an environment variable:

```bash
export GPU_TOLERATIONS='[{"key":"g5-gpu","operator":"Equal","value":"true","effect":"NoSchedule"}]'
make deploy NAMESPACE=my-namespace
```

Both examples require `STORAGE_ACCESS_KEY_ID` and `STORAGE_SECRET_ACCESS_KEY` to be set. Omit `GPU_TOLERATIONS` to use the chart values, or set it to `[]` to remove GPU tolerations. The array replaces the configured tolerations. A local values file passed through `HELM_ARGS='-f /path/to/cluster-values.yaml'` is also supported.

The internal OpenAI base URL is `http://h2o-llm-vllm/v1`, and the model ID is `RedHatAI/Llama-3.2-3B-Instruct-quantized.w8a8`. The chart version and model revision are pinned; the image is a version tag, so identical image bytes require an optional digest override. The earlier live deployment verified an 8B model; this 3B configuration has not yet been verified on the cluster.
