# H2O Knowledge Management

> **WORK IN PROGRESS - NOT READY FOR USE**

This repository is an early scaffold for an AI Quickstart exploring knowledge management with H2O.ai and Red Hat OpenShift AI.

It currently contains a small Python API scaffold deployed with Helm alongside S3-compatible storage and RHOAI-managed vLLM inference. On install, a Job uploads the configured sample document to the `documents` bucket. The API provides a health endpoint at `/healthz` and an ask endpoint at `/ask` for sending prompts to the configured model.

## Repository layout

```text
.
├── deploy/
│   └── helm/
│       └── h2o-knowledge-mgmt/  Helm chart for the API, S3 storage, document upload, and inference
└── services/
    ├── api/                     Python API, tests, and its uv.lock
    └── document-uploader/       Sample upload job and its uv.lock
```

## Installation

To deploy this project:

```bash
export STORAGE_ACCESS_KEY_ID=<my-access-key>
export STORAGE_SECRET_ACCESS_KEY=<my-secret-key>
make deploy NAMESPACE=<my-namespace>
```

This command builds the chart dependencies, then installs or upgrades the Helm release. It deploys the API, S3 storage, document upload job, and vLLM inference into the provided namespace (created if needed). If `NAMESPACE` is omitted, it uses the namespace from the current Kubernetes context.

For a GPU pool with a custom taint, set its toleration before deploying. For example:

```bash
export GPU_TOLERATIONS='[{"key":"g5-gpu","operator":"Equal","value":"true","effect":"NoSchedule"}]'
make deploy
```

## Project teardown

Remove the deployment from the current namespace, or specify the namespace used during installation:

```bash
make undeploy
make undeploy NAMESPACE=my-namespace
```

## vLLM inference

Inference is enabled by default and requires RHOAI with KServe and an available NVIDIA GPU. The pinned `llm-service` chart deploys [RedHatAI/Llama-3.2-3B-Instruct-quantized.w8a8](https://huggingface.co/RedHatAI/Llama-3.2-3B-Instruct-quantized.w8a8), which the API calls through the internal endpoint `http://h2o-llm-vllm/v1`. No Hugging Face token is required.

## Try a model request

The chart creates an HTTPS OpenShift Route for the API. Find its host with `oc get routes`, then open `https://<route-host>/docs`. In the API docs, expand `POST /ask`, select **Try it out**, enter a prompt such as `{"prompt":"In one sentence, what is a Kubernetes pod?"}`, and select **Execute**. The response contains the model's answer.

## Make targets

| Target                       | Purpose                                                        |
| ---------------------------- | -------------------------------------------------------------- |
| `make setup`                 | Install Python and development dependencies.                   |
| `make test`                  | Run API tests.                                                 |
| `make lint`                  | Check Python code style.                                       |
| `make dev`                   | Run the API locally.                                           |
| `make helm-lint`             | Check the Helm chart.                                          |
| `make helm-dependency-build` | Build dependencies from the checked-in `Chart.lock`.           |
| `make helm-dependency-update` | Update dependency versions and the checked-in `Chart.lock`.   |
| `make deploy`                | Install or upgrade the API, storage, upload job, and inference. |
| `make undeploy`              | Remove the deployment.                                         |
