# inference-platform

A reference implementation of a self-hosted LLM inference platform on
Kubernetes, built in public one step at a time. The companion blog series
walks through each step; this repo is the code.

The goal is a platform an app team can use without touching GPUs: they add a
values file for a model and get an OpenAI-compatible endpoint, metrics,
dashboards, alerts, and autoscaling. The platform team owns everything
underneath.

## Principles

**Reproducible.** Images are referenced by digest, models by revision and
checksum, tools and charts by version. There is no `latest` anywhere. The
cluster state is a function of a git commit.

**Testable without a GPU.** A mock engine stands in for vLLM locally. It
speaks the same API, reports health the same way, and emits the same metric
names. Only benchmark numbers require real hardware, and those record the
hardware they came from.

**Decisions are written down.** See `docs/adr/`. Each record states the
alternatives, the choice, and what would cause the choice to be revisited.

## Status

Step 1 of 5. The local tier works: a disposable kind cluster, a local
registry, and the mock engine running in the cluster. The Helm chart is next.

| Step | What it adds | Status |
|------|--------------|--------|
| 1 | Local cluster, mock engine, Helm chart, chart tests | in progress |
| 2 | Prometheus, Grafana, KEDA autoscaling | |
| 3 | Argo CD, OpenTofu, cloud cluster with GPU Operator | |
| 4 | Real vLLM on rented GPUs, benchmarks, SLOs | |
| 5 | Gateway, CI gates, model release pipeline, runbooks | |

## Local development

Requirements: Nix with flakes enabled, and a Docker daemon (Docker Desktop,
OrbStack, or Colima on macOS). The flake pins every CLI; Docker is the one
thing it does not provide.

    nix develop          # or `direnv allow` if you use direnv
    just                 # list recipes
    just up              # registry + 3-node kind cluster
    just smoke           # push an image through the registry and run it
    just mock-push       # build the mock engine, push it, record its digest
    just mock-smoke      # run the mock in the cluster and hit every endpoint
    just down            # delete the cluster; `just nuke` also removes the registry

`KUBECONFIG` is scoped to `local/kubeconfig` inside the dev shell, so nothing
here can touch a cluster in `~/.kube/config`.

The kind node image is pinned by digest in `local/kind-config.yml`. The mock
engine's digest is recorded in `local/mock-engine.digest` after each push and
is what the chart will reference.

## Layout

    flake.nix, flake.lock     pinned tooling for the dev shell
    justfile                  every local operation
    local/                    kind config, kubeconfig (ignored), image digests
    mock-engine/              the stand-in for vLLM
    charts/inference-service/ the chart app teams use (step 1, pending)
    docs/adr/                 architecture decision records

Later steps add `cluster/`, `models/`, `infra/`, `ci/`, `loadtest/`, and
`chaos/`.

## The mock engine

`mock-engine/` is a small FastAPI service. It exists so the chart, probes,
scraping, and autoscaling can be built against something that behaves like a
real engine at the edges without needing one:

- `/v1/chat/completions` with streaming, same request and response shape as
  vLLM's OpenAI server
- `/health` returns 503 until a configurable startup delay elapses, which is
  what the startup probe is designed around
- `/metrics` exposes vLLM's metric names, labels, and histogram buckets
- `/admin/state` forces queue depth and KV cache usage so scaling can be
  exercised on demand

It does not batch, does not model real latency under load, and knows nothing
about tokens. Anything that depends on those needs the real engine.

## Notes

The local tier runs whatever architecture the host is. On Apple Silicon that
is arm64, and the cloud tier will be amd64. The mock is built single-arch for
now; multi-arch builds arrive with the cloud tier in step 3.

Helm 4 and kind 0.32 are deliberate. Helm 3 reaches end of life in 2027 and
there is no reason for a new repo to start on it.