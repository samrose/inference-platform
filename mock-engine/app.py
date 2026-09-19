"""
Mock inference engine.

Speaks the OpenAI chat-completions API and exposes vLLM-shaped Prometheus
metrics so the platform (chart, probes, scraping, autoscaling, dashboards)
can be built and tested without a GPU.

Behavior is driven by environment variables:
  MODEL_NAME              model id reported by /v1/models and in metric labels
  STARTUP_DELAY_SECONDS   /health returns 503 until this elapses (simulates weight load)
  TTFT_MS                 simulated time to first token
  TPOT_MS                 simulated time per output token
  OUTPUT_TOKENS           default completion length when max_tokens is not sent

and by POST /admin/state {"waiting": <int>, "kv_cache_usage": <0..1>} which
forces the scaling signals so autoscaling and alerts can be exercised
deterministically.
"""
import asyncio
import json
import os
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

MODEL = os.getenv("MODEL_NAME", "mock/mock-8b")
STARTUP_DELAY = float(os.getenv("STARTUP_DELAY_SECONDS", "0"))
TTFT_MS = float(os.getenv("TTFT_MS", "200"))
TPOT_MS = float(os.getenv("TPOT_MS", "20"))
OUTPUT_TOKENS = int(os.getenv("OUTPUT_TOKENS", "32"))

# ---- state the admin endpoint can override -----------------------------------
state = {"ready": False, "waiting": 0, "kv_cache_usage": 0.0}

# ---- vLLM-shaped metrics -----------------------------------------------------
# Names, labels and histogram buckets follow vLLM's own metric definitions so
# PromQL written against this mock works unchanged against the real engine.
reg = CollectorRegistry()
LABELS = {"model_name": MODEL, "engine": "0"}
LK = list(LABELS.keys())

running = Gauge("vllm:num_requests_running", "Requests currently running", LK, registry=reg)
waiting = Gauge("vllm:num_requests_waiting", "Requests waiting in queue", LK, registry=reg)
kv_usage = Gauge("vllm:kv_cache_usage_perc", "KV cache usage (0-1)", LK, registry=reg)
gpu_usage = Gauge("vllm:gpu_cache_usage_perc", "Deprecated alias of kv_cache_usage_perc", LK, registry=reg)
ttft = Histogram(
    "vllm:time_to_first_token_seconds", "Time to first token", LK, registry=reg,
    buckets=(0.001, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.25, 0.5, 0.75,
             1.0, 2.5, 5.0, 7.5, 10.0, 20.0, 40.0, 80.0, 160.0),
)
tpot = Histogram(
    "vllm:time_per_output_token_seconds", "Time per output token", LK, registry=reg,
    buckets=(0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75,
             1.0, 2.5, 5.0, 7.5, 10.0, 20.0, 40.0, 80.0),
)
e2e = Histogram(
    "vllm:e2e_request_latency_seconds", "End-to-end request latency", LK, registry=reg,
    buckets=(0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 2.5, 5.0, 10.0, 15.0, 20.0, 30.0,
             40.0, 50.0, 60.0, 120.0, 240.0, 480.0, 960.0, 1920.0, 7680.0),
)
# Counters are exported with a _total suffix: vllm:prompt_tokens_total etc.
prompt_tok = Counter("vllm:prompt_tokens", "Prompt tokens processed", LK, registry=reg)
gen_tok = Counter("vllm:generation_tokens", "Generation tokens produced", LK, registry=reg)
success = Counter("vllm:request_success", "Successfully finished requests",
                  ["finished_reason", *LK], registry=reg)


def _sync_gauges() -> None:
    waiting.labels(**LABELS).set(state["waiting"])
    kv_usage.labels(**LABELS).set(state["kv_cache_usage"])
    gpu_usage.labels(**LABELS).set(state["kv_cache_usage"])


@asynccontextmanager
async def lifespan(app: FastAPI):
    _sync_gauges()
    running.labels(**LABELS).set(0)

    async def warm() -> None:
        # Simulates weight loading / CUDA graph capture: the process is up and
        # serving /metrics, but /health stays 503 until this completes.
        await asyncio.sleep(STARTUP_DELAY)
        state["ready"] = True

    asyncio.create_task(warm())
    yield


app = FastAPI(title="mock-engine", lifespan=lifespan)


@app.get("/health")
def health() -> Response:
    return Response(status_code=200 if state["ready"] else 503)


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(reg), media_type=CONTENT_TYPE_LATEST)


@app.get("/v1/models")
def models() -> dict:
    return {"object": "list",
            "data": [{"id": MODEL, "object": "model", "owned_by": "mock"}]}


@app.post("/admin/state")
async def admin_state(req: Request) -> dict:
    """Force queue depth / cache usage so autoscaling and alerts can be exercised."""
    body = await req.json()
    if "waiting" in body:
        state["waiting"] = int(body["waiting"])
    if "kv_cache_usage" in body:
        state["kv_cache_usage"] = float(body["kv_cache_usage"])
    _sync_gauges()
    return state


@app.post("/v1/chat/completions")
async def chat(req: Request):
    body = await req.json()
    stream = bool(body.get("stream", False))
    n_out = int(body.get("max_tokens") or OUTPUT_TOKENS)
    n_in = sum(len(str(m.get("content", "")).split()) for m in body.get("messages", []))
    rid = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    t0 = time.perf_counter()

    running.labels(**LABELS).inc()
    prompt_tok.labels(**LABELS).inc(n_in)

    def chunk(delta: dict, finish: str | None = None) -> dict:
        return {
            "id": rid,
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": MODEL,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }

    async def generate():
        try:
            await asyncio.sleep(TTFT_MS / 1000)
            ttft.labels(**LABELS).observe(time.perf_counter() - t0)
            yield f"data: {json.dumps(chunk({'role': 'assistant', 'content': ''}))}\n\n"
            for i in range(n_out):
                if i:
                    await asyncio.sleep(TPOT_MS / 1000)
                tpot.labels(**LABELS).observe(TPOT_MS / 1000)
                gen_tok.labels(**LABELS).inc()
                yield f"data: {json.dumps(chunk({'content': f'tok{i} '}))}\n\n"
            yield f"data: {json.dumps(chunk({}, 'length'))}\n\n"
            yield "data: [DONE]\n\n"
        finally:
            running.labels(**LABELS).dec()
            e2e.labels(**LABELS).observe(time.perf_counter() - t0)
            success.labels(finished_reason="length", **LABELS).inc()

    if stream:
        return StreamingResponse(generate(), media_type="text/event-stream")

    # Non-streaming: drive the same generator so timing and metrics match.
    async for _ in generate():
        pass
    text = " ".join(f"tok{i}" for i in range(n_out))
    return {
        "id": rid,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": MODEL,
        "choices": [{"index": 0,
                     "message": {"role": "assistant", "content": text},
                     "finish_reason": "length"}],
        "usage": {"prompt_tokens": n_in, "completion_tokens": n_out,
                  "total_tokens": n_in + n_out},
    }
