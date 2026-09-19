# Pin the base image by digest. Get it with:
#   docker pull python:3.12-slim
#   docker inspect --format '{{index .RepoDigests 0}}' python:3.12-slim
# On an Apple Silicon host this is the arm64 manifest digest; the multi-arch
# (index) digest is adopted in step 3 when the cloud tier needs amd64.
FROM python:3.12-slim@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9
ENV PROMETHEUS_DISABLE_CREATED_SERIES=true
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 8000
# Same port and listening shape as `vllm serve` so the chart needs no mock-specific branches.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
