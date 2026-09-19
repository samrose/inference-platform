# 0003. Local cluster is kind with a local OCI registry

Status: accepted, 2026-09-18

## Context

The platform needs to be exercised on a laptop with no GPU. Images built
locally have to reach cluster nodes without a round trip through a public
registry.

Options considered: kind, k3d, minikube, a rented cloud node used as the dev
environment.

## Decision

kind, pinned to a specific node image digest, with three nodes (one control
plane, two workers) and a `registry:2` container on the `kind` Docker
network. containerd on each node is configured in `certs.d` mode so pulls
from `localhost:5001` resolve to the registry container. All of this is
driven from the `justfile`; `just up` is idempotent and `just down` removes
the cluster but keeps the registry so pushed images survive a rebuild.

`KUBECONFIG` is set to `local/kubeconfig` inside the dev shell so the local
cluster cannot be confused with any other.

## Consequences

A disposable cluster in about a minute, a registry round trip verified by
`just smoke`, and an image-pinning workflow identical in shape to the cloud
tier.

Two workers exist so multi-replica scheduling and node drains can be tested.
The cluster runs on the host architecture (arm64 on Apple Silicon), which
differs from the cloud tier; see 0005.

The first bug in the repo was here: a template-escaping mistake in the
justfile meant the registry was never attached to the `kind` network, and
the symptom looked like an architecture problem. `just smoke` now prints pod
events on failure so the cause is visible.

## Revisit when

kind cannot represent something the platform depends on (GPU device
plugins, RDMA), at which point that test moves to the ephemeral cloud tier.
