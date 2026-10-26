# H2O Knowledge Management

> **WORK IN PROGRESS - NOT READY FOR USE**

This repository is an early scaffold for an AI Quickstart exploring knowledge management with H2O.ai and Red Hat OpenShift AI.

One NVIDIA RTX PRO 6000 Blackwell 96 GB is partitioned into **two 48 GB MIG instances**, exclusively for H2O's model and function pods. Chat inference uses an **external OpenAI-compatible endpoint**, such as MaaS. The application chart deploys no local model server and requests no GPU devices. H2O owns and deploys its two workloads separately.

The chart deploys a small Python API, S3-compatible storage, and a Job that uploads a sample document to the `documents` bucket. The API provides `/healthz` and `/ask`; `/ask` sends text prompts to the configured external model.

## Repository layout

```text
.
├── .env.example                External endpoint and deployment configuration
├── deploy/
│   ├── helm/h2o-knowledge-mgmt/ Application Helm chart
│   └── mig/                    Administrator-owned 48/48 GPU configuration
├── docs/
│   └── gpu-mig-setup.md         H2O GPU setup, allocation, and validation
└── services/
    ├── api/                    Python API, tests, and uv.lock
    └── document-uploader/      Sample upload job and uv.lock
```

## GPU requirements

Ask a cluster administrator to complete the [GPU and MIG setup](docs/gpu-mig-setup.md) for the RTX PRO 6000 Blackwell: two `2g.48gb` instances, one for the H2O model pod and one for the H2O function pod. Both H2O workloads must support Blackwell SM120 and fit in their individual partitions, including runtime overhead.

The application and external chat endpoint do not consume either GPU instance. H2O's deployment owners configure their own node selection and GPU requests.

## Configure the external endpoint

```bash
cp .env.example .env
# Edit .env with your endpoint, exact model identifier, and deployment settings.
```

Set `LLM_BASE_URL` to the provider's API base URL, including `/v1` when required. The API appends `/chat/completions`. Set `LLM_MODEL` to the exact model ID provided by MaaS or your endpoint operator. Set `LLM_API_KEY` if a Bearer token is required, or leave it empty for unauthenticated endpoints. Set `STORAGE_ACCESS_KEY_ID` and `STORAGE_SECRET_ACCESS_KEY` for the chart's S3-compatible storage. These settings can also be supplied through environment variables when omitted from `.env`; the endpoint URL, model ID, and storage credentials are required for deployment.

## Installation

After the administrator prepares H2O's GPU partitions, configure `.env`, then run:

```bash
make deploy NAMESPACE=<my-namespace>
```

`make deploy` builds chart dependencies and installs the API, credential Secret, storage, and sample upload Job into the provided namespace (created if needed). If `NAMESPACE` is omitted, it uses the namespace from the current Kubernetes context.

## Try a model request

The chart creates an HTTPS OpenShift Route for the API. Find its host with `oc get routes`, then open `https://<route-host>/docs`. In the API docs, expand `POST /ask`, select **Try it out**, enter a prompt such as `{"prompt":"In one sentence, what is a Kubernetes pod?"}`, and select **Execute**. The response contains the model's answer.

## Project teardown

```bash
make undeploy
make undeploy NAMESPACE=my-namespace
```

This removes the application release, including any chart-managed LLM Secret. It leaves H2O deployments, the administrator's MIG layout, operators, and ClusterPolicy intact. See [Restore GPU configuration](docs/gpu-mig-setup.md#restore-gpu-configuration) for administrator cleanup.


## Development validation

```bash
make test
make lint
make helm-lint
```

## Make targets

| Target | Purpose |
| --- | --- |
| `make setup` | Install Python and development dependencies. |
| `make test` | Run API tests. |
| `make lint` | Check Python code style. |
| `make dev` | Load `.env` and run the API locally. |
| `make helm-lint` | Check the application Helm chart. |
| `make helm-dependency-build` | Build dependencies from the checked-in Chart.lock. |
| `make helm-dependency-update` | Update dependency versions and Chart.lock. |
| `make deploy` | Deploy the API, storage, and upload Job using external inference. |
| `make undeploy` | Remove the application release. |
