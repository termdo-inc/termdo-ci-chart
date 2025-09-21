# Termdo CI Helm Chart

Helm chart that provisions the Tekton resources required to run Termdo's continuous integration pipeline on Kubernetes. The chart wires Bitbucket webhook events into Tekton Triggers, runs a multi-stage BuildKit pipeline, and publishes container images to Harbor.

## Components

- **Pipeline (`templates/ci.pipeline.yaml`)** – Clones the repository, validates the workspace, runs tests, builds the image, and pushes it to Harbor.
- **Tasks (`templates/tasks/*.yaml`)** – Encapsulated Tekton tasks (`clone`, `analyze`, `test`, `build`, `push`) using `alpine`, `moby/buildkit`, and `quay.io/skopeo/stable` containers.
- **Triggers (`templates/triggers/*.yaml`)** – Bitbucket `repo:refs_changed` EventListener plus TriggerBinding/TriggerTemplate to launch `PipelineRun`s for dev/test branches and prod tags.
- **Support resources (`templates/_common/*.yaml`)** – Service account, RBAC, Bitbucket SSH ConfigMap/Secret, Harbor robot credentials, and webhook token Secret.

## Prerequisites

- Kubernetes >= 1.23 with Tekton Pipelines and Tekton Triggers installed.
- Cluster nodes capable of running privileged BuildKit (`moby/buildkit:latest`).
- Harbor registry with robot account credentials.
- Bitbucket (Cloud or Server) repository accessible via SSH.
- Helm 3.

## Installation

Add this chart to your manifests (or package it) and install with your customized values:

```bash
helm upgrade --install termdo-ci ./termdo-ci-chart \
  --namespace ci \
  --create-namespace \
  -f your-values.yaml
```

The EventListener is exposed as a `NodePort` (default `30019`). Ensure the node/port is reachable from Bitbucket or place it behind your ingress/load balancer.

## Configuration

Key values from `values.yaml`:

| Key | Description | Default |
| --- | --- | --- |
| `project.name` | Base project slug (used to derive Harbor project names). | `your_project_name_without_env_suffix` |
| `project.dockerfile.path` | Path containing the Dockerfile. | `.` |
| `project.dockerfile.name` | Dockerfile name. | `Dockerfile` |
| `project.dockerfile.testStage` | Multistage target used for tests. | `tester` |
| `harbor.host` | Harbor registry hostname. | `your_harbor_registry_host` |
| `harbor.secret.name` | Harbor robot username. | `your_harbor_robot_account_name` |
| `harbor.secret.token` | Harbor robot token/password. | `your_harbor_robot_account_token` |
| `bitbucket.host` | Bitbucket SSH host. | `your_bitbucket_server_host` |
| `bitbucket.port` | Bitbucket SSH port. | `your_bitbucket_ssh_port` |
| `bitbucket.branch.dev` | Dev branch tracked by CI. | `dev` |
| `bitbucket.branch.test` | Test branch tracked by CI. | `test` |
| `bitbucket.eventListener.nodePort` | NodePort exposed by EventListener Service. | `30019` |
| `bitbucket.config.knownHosts` | Contents of Bitbucket SSH known hosts entry. | `your_bitbucket_known_hosts_entry` |
| `bitbucket.secret.webhook` | Shared secret for webhook validation. | `your_bitbucket_webhook_secret` |
| `bitbucket.secret.ssh` | Base64-encoded SSH private key for clone task. | `your_base64_encoded_bitbucket_ssh_private_key` |
| `shaLength` | Length of git SHA used in image tags. | `7` |
| `pipeline.timeouts.*` | Tekton timeouts for pipeline, tasks, finally. | `1h0m0s`, `0h45m0s`, `0h15m0s` |
| `pipeline.params.retries` | Clone retry attempts. | `5` |
| `pipeline.params.delay` | Delay between clone retries (seconds). | `3` |
| `workspace.size` | PVC size allocated per PipelineRun. | `2Gi` |

> **Secrets:** `harbor.secret.*` and `bitbucket.secret.*` values are rendered directly into Kubernetes Secret manifests. Provide already base64-encoded data where indicated.

### Example values file

```yaml
project:
  name: termdo
  dockerfile:
    name: Dockerfile
    path: "."
    testStage: tester

harbor:
  host: registry.example.com
  secret:
    name: robot$ci-bot
    token: "robot-token"

bitbucket:
  host: bitbucket.example.com
  port: 7999
  branch:
    dev: develop
    test: qa
  eventListener:
    nodePort: 30019
  config:
    knownHosts: "bitbucket.example.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ..."
  secret:
    webhook: "super-secret"
    ssh: "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo..."

shaLength: 7

pipeline:
  timeouts:
    pipeline: 1h0m0s
    tasks: 0h45m0s
    finally: 0h15m0s
  params:
    retries: 3
    delay: 5

workspace:
  size: 5Gi
```

## Pipeline flow

1. **clone-task** – Uses `alpine/git` with mounted SSH key and known hosts to fetch sources. Retries according to `pipeline.params.*`.
2. **analyze-task** – Verifies the expected Dockerfile exists.
3. **test-task** – Runs BuildKit against the configured test stage, exporting an OCI cache to the shared workspace.
4. **build-task** – Reuses the cache, normalizes repository and tag names, applies env-specific build args for `web`, and produces an OCI image tarball.
5. **push-task** – Validates Harbor auth, normalizes tags, and pushes via `skopeo` to `{{ project.name }}-{env}/{repository}:{tag}`.

Prod tags must look like `vX.Y.Z`. Branch builds use the first `shaLength` characters of the commit hash.

## Triggering builds

The chart exposes a Tekton Triggers EventListener named `bitbucket-el`. Point a Bitbucket webhook at the listener's NodePort URL and enable the `repo:refs_changed` event. Provide the shared secret in `bitbucket.secret.webhook` so the Bitbucket interceptor can validate the payload.

### Event flow

- Bitbucket sends a refs changed payload to the EventListener Service.
- The Bitbucket interceptor authenticates the request with the webhook secret.
- A CEL interceptor filters the event for dev, test, or prod rules and enriches the payload with additional fields.
- The TriggerBinding `refs-changed-tb` maps those fields onto Tekton parameters.
- The TriggerTemplate `refs-changed-tt` instantiates a `PipelineRun` with the bound parameters and PVC template.

### CEL filters and overlays

Each trigger block (`dev`, `test`, `prod`) applies a CEL expression that selects only the relevant changes:

- **dev**: branch updates that match `bitbucket.branch.dev`.
- **test**: branch updates that match `bitbucket.branch.test`.
- **prod**: newly created tags (release builds).

When a change passes the filter, the interceptor defines four overlays that become available as `$(extensions.*)` variables:

| Overlay key | Source in payload | Purpose |
| --- | --- | --- |
| `env` | Literal (`"dev"`, `"test"`, `"prod"`) | Selects environment specific behavior in tasks. |
| `url` | First SSH clone URL under `body.repository.links.clone` | Feeds the repo URL to `clone-task`. |
| `revision` | The branch head SHA or tag name from the change record | Becomes the git revision/tag for build and push logic. |
| `repository` | `body.repository.slug` | Used by normalization logic to create Harbor repo names. |

`refs-changed-tb` stores these overlays as parameters so they can be consumed by the template and pipeline. This keeps the EventListener free of hard coded environment logic beyond the CEL expressions.

### Manual trigger testing

You can simulate webhook requests locally by posting a recorded payload with `curl` to the NodePort. Be sure to include `X-Event-Key: repo:refs_changed` and the correct `X-Hub-Signature` header.

## Development and testing

- Shell helpers under `tests/` mirror the repository/tag normalization logic; use them when adjusting those scripts.
- When updating tasks, verify BuildKit and Skopeo images still satisfy required capabilities in your cluster (privileged access, AppArmor profile).
- Consider enabling TLS verification in `push-task` once Harbor certificates are trusted by the cluster.

## License

This chart is distributed under the terms of the [MIT License](LICENSE.md).
