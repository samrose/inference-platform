"""
Streaming load generator. Runs as a pod inside the cluster, against a
release's Service, so a rollout or a node drain that drops requests shows up
as a number rather than a feeling.

Every request is counted by outcome:
  ok          stream reached data: [DONE]
  truncated   HTTP 200 but the stream ended early (pod stopped mid-response)
  http_<code> non-2xx response
  <ExcName>   connection-level failure (refused, reset, timeout)

Configured by environment:
  TARGET              base URL, e.g. http://mock-inference-service:8000
  DURATION_SECONDS    how long to run
  CONCURRENCY         parallel request loops
  MODEL_NAME          model id to send

Stdlib only, so it runs unchanged in the mock engine's image. Each request
opens a new connection, which is the simplest client and also the most
forgiving one; a keep-alive client can see one reset per retired pod.
"""

import collections
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

URL = os.environ.get("TARGET", "http://mock-inference-service:8000") + "/v1/chat/completions"
DURATION = float(os.environ.get("DURATION_SECONDS", "120"))
CONCURRENCY = int(os.environ.get("CONCURRENCY", "4"))
MODEL = os.environ.get("MODEL_NAME", "mock/mock-8b")

BODY = json.dumps(
    {
        "model": MODEL,
        "stream": True,
        "max_tokens": 20,
        "messages": [{"role": "user", "content": "hi"}],
    }
).encode()

counts: collections.Counter[str] = collections.Counter()
lock = threading.Lock()
started = time.monotonic()
deadline = started + DURATION


def one_request() -> str:
    req = urllib.request.Request(URL, data=BODY, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            done = False
            for line in resp:
                if line.startswith(b"data: [DONE]"):
                    done = True
            return "ok" if done else "truncated"
    except urllib.error.HTTPError as e:
        return f"http_{e.code}"
    except Exception as e:  # noqa: BLE001 - every failure kind is a count, not a crash
        return type(e).__name__


def worker() -> None:
    while time.monotonic() < deadline:
        outcome = one_request()
        with lock:
            counts[outcome] += 1


threads = [threading.Thread(target=worker, daemon=True) for _ in range(CONCURRENCY)]
for t in threads:
    t.start()

print(f"load: {CONCURRENCY} streams against {URL} for {int(DURATION)}s", flush=True)
while any(t.is_alive() for t in threads):
    time.sleep(5)
    with lock:
        snapshot = dict(counts)
    print(
        f"t={int(time.monotonic() - started):4d}s total={sum(snapshot.values()):5d} {snapshot}",
        flush=True,
    )

with lock:
    final = dict(counts)
failures = {k: v for k, v in final.items() if k != "ok"}
print(
    f"final total={sum(final.values())} ok={final.get('ok', 0)} failures={failures or 'none'}",
    flush=True,
)
sys.exit(1 if failures else 0)
