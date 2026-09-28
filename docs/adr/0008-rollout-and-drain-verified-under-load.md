# 0008. Rollout and drain behaviour is verified under load, from inside the cluster

Status: accepted, 2026-09-27

## Context

ADR 0007 claims that a rolling update and a node drain complete without
failed requests. The unit tests prove the manifests say the right thing;
they cannot prove Kubernetes does the right thing with them. That needs
traffic flowing while pods are replaced, and a count of what happened to
every request.

Options considered: `kubectl port-forward` plus a load tool on the laptop;
a load-testing tool (k6, vegeta, guidellm) run in the cluster; a small
script in the mock engine's own image run as a pod.

## Decision

`loadtest/load.py` runs as a pod inside the cluster, using the mock
engine's image (which is already in the local registry and has Python),
against the release's Service DNS name. It opens N concurrent loops of
streaming chat completions for a fixed duration and counts every request
by outcome: `ok` (stream reached `[DONE]`), `truncated`, `http_<code>`, or
the exception class for a connection failure. It exits 1 if anything but
`ok` was counted. Stdlib only, so it needs no extra image.

Three `just` recipes drive it:

- `load`: run the pod, optionally pinned to a node.
- `rollout-test`: start load, `helm upgrade` with a changed env value so
  every pod is replaced, wait for the rollout, report the counts.
- `drain-test`: scale to 2 replicas, start load on the other worker,
  `kubectl drain` the node running the first pod, uncordon, report.

`kubectl port-forward` was rejected because it binds to one pod at
connect time and does not follow the Service through a rollout, so it
reports failures the Service would not have. A dedicated load tool is
deferred: the benchmark parts need one (guidellm is already in the flake),
but for "did any request fail" a counter is enough and one fewer image to
pin.

## Consequences

`just rollout-test` and `just drain-test` on the local cluster are the
acceptance test for any change to probes, drain settings, or the
Deployment strategy. First runs: 932 requests through a rollout and 916
through a drain, zero failures. A control run with `preStopSeconds=0` and
`terminationGracePeriodSeconds=1` counted 2 refused connections in 925,
which is what proves the zero means something.

The client opens a new connection per request, which is the most
forgiving client. A keep-alive client can see one reset per retired pod;
measuring that is part of the benchmark work. Latency is not measured
here at all, since the mock's timings are configured, not real.

These tests need a cluster and are laptop-only until CI gets one (ADR
0006, revisit clause).

## Revisit when

The benchmark parts introduce a real load tool, at which point this
script is either replaced by it or kept only as the fast smoke check.
