# 0007. The chart: one model per release, digest-only images, probes sized for weight loading

Status: accepted, 2026-09-27

## Context

An app team needs to deploy a model without knowing how the engine is run.
The chart is the interface they see, so its shape decides how much they
have to know and how much they can get wrong. The engine takes a long time
to become ready (weights load, CUDA graphs capture) and a pod that is
Ready before then receives traffic it cannot serve; part 1 showed this with
a bare `kubectl run` of the mock. Streaming responses can be long, so a
rollout that stops a pod the moment its replacement is Ready cuts streams
off.

Options considered for scope: one chart per model release; one chart that
takes a list of models; an operator with a `Model` custom resource.

## Decision

`charts/inference-service` deploys one model per Helm release. The values
interface is:

- `image.repository` and `image.digest`, both required. `image.tag` is
  refused by the schema and by the template. A deploy is always the exact
  bytes that were tested.
- `model.name`, `engine.args`, `engine.env`: what the engine is and how it
  is started. The chart has no mock-specific branches; the mock and vLLM
  differ only in these values.
- `engine.loadTimeoutSeconds` (default 600): how long the engine may take
  to load. The startup probe's `failureThreshold` is derived from it and
  `probes.periodSeconds` (rounded up), and readiness and liveness probes
  do not run until the startup probe has passed once. The liveness
  threshold is generous because restarting a loaded engine drops every
  request it holds.
- `rollout.preStopSeconds` (10) and `rollout.terminationGracePeriodSeconds`
  (90), with `maxUnavailable: 0` and `maxSurge: 1`: a serving pod is only
  removed after its replacement is Ready, keeps serving through the
  preStop sleep while endpoints propagate its removal, and is then given
  the grace period to finish streams in flight.
- A PodDisruptionBudget with `minAvailable: 1`, rendered only when
  `replicaCount > 1`, so a node drain waits for a replacement before
  evicting the last serving pod.
- `prometheus.io/*` pod annotations for scraping. A ServiceMonitor is part
  3's, once the CRD exists in the cluster.

`values.schema.json` validates types at install time. It exists because of
a specific failure: an env value set with `--set X=1790549118` was stored
by Helm as a number, read back as a float on the next `--reuse-values`
upgrade, rendered as `1.790549118e+09`, and caused a full rollout on what
was meant to be a scale-only change. Env values must be strings
(`--set-string`); the schema turns a surprise rollout into an install
error.

## Consequences

An app team writes a values file with a repository, a digest, a model name
and a resource request, and gets an endpoint that becomes Ready only when
the engine can serve. Rolling updates and node drains complete without
failed requests; ADR 0008 records how that is verified.

One release per model means N models are N releases and N values files,
which is what Argo CD (part 4) manages well. A list-of-models chart was
rejected because one bad model would block the release of all of them, and
an operator was rejected as more machinery than five posts justify.

The drain defaults are sized for the mock. Whether 90 seconds is enough
for vLLM to finish a long streamed response is a part 5 question, and the
rollout test exists to answer it.

## Revisit when

A model needs more than one container (a sidecar for a tokenizer or a
speculative-decoding draft model), which the single-container template
does not express. Or when the number of releases makes per-release values
files unmanageable, which is the case for an operator.
