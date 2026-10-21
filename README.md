# H2O Knowledge Management

> **WORK IN PROGRESS - NOT READY FOR USE**

This repository is an early scaffold for an AI Quickstart exploring knowledge management with H2O.ai and Red Hat OpenShift AI.

It currently contains a small Python API scaffold deployed with Helm alongside S3-compatible storage and one RHOAI/KServe-managed vLLM server on a 40 GB MIG partition of one NVIDIA A100 80 GB GPU. Two additional 20 GB MIG partitions are reserved for H2O to deploy its two models independently. On install, a Job uploads the configured sample document to the `documents` bucket. The API provides a health endpoint at `/healthz` and an ask endpoint at `/ask` for sending prompts to the OpenShift AI model server.

## Repository layout

```text
.
├── deploy/
│   ├── helm/
│   │   └── h2o-knowledge-mgmt/  Helm chart for the API, S3 storage, document upload, and inference
│   └── mig/                    Administrator-owned GPU partition configuration
├── docs/
│   └── gpu-mig-setup.md        Administrator GPU/MIG setup and H2O allocation guide
└── services/
    ├── api/                     Python API, tests, and its uv.lock
    └── document-uploader/       Sample upload job and its uv.lock
```

## GPU requirements

Before installing, ask a cluster administrator to complete the [GPU and MIG cluster setup](docs/gpu-mig-setup.md) for one A100 80 GB with a 20/20/40 layout. That guide covers the NVIDIA operators, partition configuration, verification, and [H2O's two 20 GB allocations](docs/gpu-mig-setup.md#use-the-two-reserved-20-gb-partitions-for-h2o).

The application uses one `nvidia.com/mig-3g.40gb` instance. Set `GPU_NODE` to the prepared node's `kubernetes.io/hostname` label. The application Helm chart does not configure the GPU or deploy H2O's models.

## Installation

After the administrator completes the [MIG setup](docs/gpu-mig-setup.md):

```bash
export STORAGE_ACCESS_KEY_ID=<my-access-key>
export STORAGE_SECRET_ACCESS_KEY=<my-secret-key>
export GPU_NODE=<selected-node-hostname-label>
make deploy NAMESPACE=<my-namespace> GPU_NODE="$GPU_NODE"
```

This command builds the chart dependencies, then installs the Helm release. It deploys the API, S3 storage, document upload job, and one vLLM server into the provided namespace (created if needed). If `NAMESPACE` is omitted, it uses the namespace from the current Kubernetes context. `GPU_NODE` is required when inference is enabled; the predictor selects its `kubernetes.io/hostname` label. Helm installation returning successfully does not mean model loading has finished.

For a GPU pool with a custom taint, set its toleration before deploying. For example:

```bash
export GPU_TOLERATIONS='[{"key":"a100-gpu","operator":"Equal","value":"true","effect":"NoSchedule"},{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
make deploy GPU_NODE="$GPU_NODE"
```

This list replaces the default tolerations. Include every taint that applies to your GPU node. Use `HELM_ARGS='-f my-values.yaml'` for other configuration overrides. For an external model endpoint, set `inference.enabled=false` and configure `llm.baseUrl` and `llm.model`; no GPU node is required in that case.

## Project teardown

Remove the deployment from the current namespace, or specify the namespace used during installation:

```bash
make undeploy
make undeploy NAMESPACE=my-namespace
```

This removes application-managed inference resources but leaves the administrator's MIG layout, operators, and ClusterPolicy intact. See [Restore GPU configuration](docs/gpu-mig-setup.md#restore-gpu-configuration) for administrator cleanup.

## vLLM inference

The chart serves [Mistral Small 3.1 24B INT8](https://huggingface.co/RedHatAI/Mistral-Small-3.1-24B-Instruct-2503-quantized.w8a8) through one KServe-managed vLLM server on the 40 GB MIG partition. The model is public and ungated, so no Hugging Face token is required. H2O manages its two models separately on the 20 GB partitions.

The internal endpoint is `http://h2o-llm-vllm/v1`. `/ask` sends text prompts to this endpoint. Tool calling is enabled for clients that supply tool definitions and handle the results; `/ask` does not execute tools.

Configure the single server in [values.yaml](deploy/helm/h2o-knowledge-mgmt/values.yaml). Defaults allow 16,384 tokens per sequence (input plus output) and 2 concurrent sequences. The server uses one replica with `Recreate` updates, so it is unavailable while a replacement loads.

Use the API docs below for a basic inference check. See [live A100 validation](docs/gpu-mig-setup.md#validate-inference-on-the-a100) for GPU allocation, tool calling, and concurrent workload checks.

## Try a model request

Wait for `h2o-llm` to report Ready in the OpenShift AI dashboard. The chart creates an HTTPS OpenShift Route for the API. Find its host with `oc get routes`, then open `https://<route-host>/docs`. In the API docs, expand `POST /ask`, select **Try it out**, enter a prompt such as `{"prompt":"In one sentence, what is a Kubernetes pod?"}`, and select **Execute**. The response contains the model's answer.

## Development validation

Run the API tests, Python lint, and Helm lint:

```bash
make test
make lint
make helm-lint
```

During chart development, render manifests with dummy credentials for inspection:

```bash
helm template h2o-knowledge-mgmt deploy/helm/h2o-knowledge-mgmt \
  --set-string inference.nodeName=test-a100 \
  --set-string aws-compatible-storage.s3.accessKeyId=test-access \
  --set-string aws-compatible-storage.s3.secretAccessKey=test-secret \
  > /tmp/h2o-knowledge-mgmt-rendered.yaml
```

Check that there is one InferenceService requesting one `nvidia.com/mig-3g.40gb`, that it selects the intended node, and that the API selectors do not match inference pod labels. No application workload should request H2O's `nvidia.com/mig-2g.20gb` devices. Complete the [live A100 checks](docs/gpu-mig-setup.md#validate-inference-on-the-a100) before considering the serving configuration validated.

## Make targets


| Target                        | Purpose                                                     |
| ----------------------------- | ----------------------------------------------------------- |
| `make setup`                  | Install Python and development dependencies.                |
| `make test`                   | Run API tests.                                              |
| `make lint`                   | Check Python code style.                                    |
| `make dev`                    | Run the API locally.                                        |
| `make helm-lint`              | Check the Helm chart.                                       |
| `make helm-dependency-build`  | Build dependencies from the checked-in `Chart.lock`.        |
| `make helm-dependency-update` | Update dependency versions and the checked-in `Chart.lock`. |
| `make deploy`                 | Deploy the API, storage, upload job, and inference.         |
| `make undeploy`               | Remove the deployment.                                      |
