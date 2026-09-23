# Pin the base image by its multi-arch index digest, so this FROM line resolves
# to the right platform on an arm64 laptop and on an amd64 CI runner or GPU
# node (ADR 0005). Get it with:
#   docker buildx imagetools inspect python:3.12-slim | head -3
# The image built from it is still single-arch (the host's) until part 4.
FROM python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
ENV PROMETHEUS_DISABLE_CREATED_SERIES=true
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 8000
# Same port and listening shape as `vllm serve` so the chart needs no mock-specific branches.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
