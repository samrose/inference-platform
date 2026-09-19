# 0004. A mock engine stands in for vLLM locally

Status: accepted, 2026-09-19

## Context

The chart, probes, metrics scraping, dashboards, and autoscaling can all be
built and tested without a GPU if there is a process that behaves like the
real engine at its boundaries. Running vLLM on CPU or a small model on a
laptop GPU gives real behavior but slow iteration, no control over the
scaling signals, and metrics that differ from the production build.

## Decision

`mock-engine/` is a small FastAPI service that imitates vLLM's boundaries
and nothing else:

- OpenAI-compatible `/v1/chat/completions` with SSE streaming, and
  `/v1/models`
- `/health` returns 503 until a configurable startup delay elapses,
  simulating weight loading
- `/metrics` uses vLLM's metric names, labels, and histogram buckets;
  `prometheus_client`'s `_created` series are disabled so the output is a
  subset of the real engine's
- `/admin/state` forces queue depth and KV cache usage
- port 8000 and the same paths as `vllm serve`, so the chart has no
  mock-specific branches

Request concurrency (`num_requests_running`) is real; queue depth and cache
usage are set explicitly. Those are the signals autoscaling depends on, and
tests need to control them deterministically.

## Consequences

Everything above the engine can be developed and tested on a laptop. PromQL
and KEDA queries written against the mock work unchanged against vLLM.

The mock does not batch, does not model latency under load, and does not
tokenize. No performance conclusion can be drawn from it. Benchmark numbers
come only from the real engine on real hardware and record that hardware.

## Revisit when

vLLM changes metric names or health semantics, in which case the mock is
updated to match and the change is noted here.