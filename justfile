# justfile — one entrypoint for every local operation.
# Run `just` to list recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load

# ---- configuration (override with `just VAR=value recipe` or a .env file) ----
cluster := env_var_or_default("CLUSTER_NAME", "inference")
reg_name := env_var_or_default("REGISTRY_NAME", "kind-registry")
reg_port := env_var_or_default("REGISTRY_PORT", "5001")
kind_config := "local/kind-config.yml"
kubeconfig := "local/kubeconfig"
chart := "charts/inference-service"

export KUBECONFIG := kubeconfig

# default: show available recipes
default:
    @just --list --unsorted

# ---- lifecycle ----------------------------------------------------------------

# create the local registry, the kind cluster, and wire them together
up: registry
    @if kind get clusters | grep -qx "{{ cluster }}"; then \
        echo "cluster '{{ cluster }}' already exists"; \
    else \
        kind create cluster --name "{{ cluster }}" --config "{{ kind_config }}" --kubeconfig "{{ kubeconfig }}"; \
    fi
    just _connect-registry
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    just status

# delete the cluster (registry is left running; `just nuke` removes both)
down:
    kind delete cluster --name "{{ cluster }}"
    rm -f "{{ kubeconfig }}"

# delete the cluster and the registry container
nuke: down
    docker rm -f "{{ reg_name }}" >/dev/null 2>&1 || true

# start the local OCI registry if it isn't running
registry:
    @if [ "$(docker inspect -f '{{{{.State.Running}}' "{{ reg_name }}" 2>/dev/null)" != "true" ]; then \
        docker run -d --restart=always -p "127.0.0.1:{{ reg_port }}:5000" \
            --network bridge --name "{{ reg_name }}" registry:2; \
    fi

# tell containerd on every node about the registry and advertise it to tooling
_connect-registry:
    #!/usr/bin/env bash
    set -euo pipefail
    reg_dir="/etc/containerd/certs.d/localhost:{{ reg_port }}"
    for node in $(kind get nodes --name "{{ cluster }}"); do
        docker exec "$node" mkdir -p "$reg_dir"
        cat <<EOF | docker exec -i "$node" cp /dev/stdin "$reg_dir/hosts.toml"
    [host."http://{{ reg_name }}:5000"]
    EOF
    done
    if [ "$(docker inspect -f='{{{{json .NetworkSettings.Networks.kind}}' "{{ reg_name }}")" = "null" ]; then
        docker network connect kind "{{ reg_name }}"
    fi
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: local-registry-hosting
      namespace: kube-public
    data:
      localRegistryHosting.v1: |
        host: "localhost:{{ reg_port }}"
        help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
    EOF

# cluster and registry health at a glance
status:
    kubectl get nodes -o wide
    @echo "registry: localhost:{{ reg_port }} ($(docker inspect -f '{{{{.State.Status}}' "{{ reg_name }}" 2>/dev/null || echo absent))"

# ---- verification ---------------------------------------------------------------

# prove the registry round-trips: push an image, run it in the cluster
# (no --platform: Docker pulls the host arch, which is what the kind nodes run)
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    img="localhost:{{ reg_port }}/busybox:1.36"
    docker pull busybox:1.36
    docker tag busybox:1.36 "$img"
    docker push "$img"
    kubectl delete pod smoke --ignore-not-found >/dev/null
    kubectl run smoke --restart=Never --image="$img" -- echo "registry round-trip OK"
    if ! kubectl wait pod/smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s; then
        echo "--- smoke pod did not succeed; describe follows ---"
        kubectl describe pod smoke | sed -n '/Events:/,$p'
        kubectl delete pod smoke --ignore-not-found >/dev/null
        exit 1
    fi
    kubectl logs smoke
    kubectl delete pod smoke >/dev/null
# ---- linters (every tool comes from the flake; see ADR 0006) --------------------

# rewrite files into canonical form; `just lint-fmt` is the check-only version
fmt:
    ruff format mock-engine
    nixfmt flake.nix
    just --fmt --unstable

# formatting is canonical (no rewrites, fails if `just fmt` would change anything)
lint-fmt:
    ruff format --check mock-engine
    nixfmt --check flake.nix
    just --fmt --check --unstable

# python, nix, dockerfile, yaml, markdown, workflows, spelling, secrets
lint-repo:
    ruff check mock-engine
    statix check .
    deadnix --fail .
    hadolint mock-engine/Dockerfile
    yamllint --strict .
    markdownlint-cli2 "**/*.md"
    actionlint
    typos
    gitleaks git --no-banner --redact
    just _lint-shell

# shellcheck every recipe that runs as a bash script (those with a shebang line)
_lint-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    for r in $(just --summary); do
        body=$(just --show "$r" | sed -n '/^    #!/,$p' | sed 's/^    //')
        [ -n "$body" ] || continue
        if ! printf '%s\n' "$body" | shellcheck -s bash -; then
            echo "shellcheck: recipe $r"; status=1
        fi
    done
    exit $status

# ---- chart quality gates ----------------------------------------------------------

# static checks: lint, render, validate against the pinned Kubernetes version
lint:
    helm lint "{{ chart }}" -f "{{ chart }}/ci/lint-values.yaml"
    helm template test "{{ chart }}" -f "{{ chart }}/ci/lint-values.yaml" \
        | kubeconform -strict -summary -kubernetes-version "$(just _k8s-version)"

# unit tests for the chart's templates
test:
    helm unittest "{{ chart }}"

# everything CI runs
check: lint-fmt lint-repo lint test

# ---- git hooks --------------------------------------------------------------------

# install a pre-commit hook that runs `just precommit` (once per clone)
hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    hook="$(git rev-parse --git-path hooks)/pre-commit"
    cat > "$hook" <<'EOF'
    #!/usr/bin/env bash
    # installed by `just hooks`; runs inside the flake's ci shell if tools are not on PATH
    if command -v yamllint >/dev/null 2>&1; then
        exec just precommit
    else
        exec nix develop .#ci -c just precommit
    fi
    EOF
    chmod +x "$hook"
    echo "installed $hook"

# fast checks on staged files only; the full set is `just check`
precommit:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM)
    [ ${#files[@]} -gt 0 ] || exit 0
    has() { printf '%s\n' "${files[@]}" | grep -qE "$1"; }
    has '\.py$'                    && ruff format --check mock-engine && ruff check mock-engine
    has '^flake\.nix$'             && nixfmt --check flake.nix
    has '^justfile$'               && just --fmt --check --unstable
    has '^mock-engine/Dockerfile$' && hadolint mock-engine/Dockerfile
    mapfile -t yamls < <(printf '%s\n' "${files[@]}" | grep -E '\.ya?ml$' || true)
    [ ${#yamls[@]} -eq 0 ]         || yamllint --strict "${yamls[@]}"
    has '^\.github/workflows/'     && actionlint
    mapfile -t mds < <(printf '%s\n' "${files[@]}" | grep -E '\.md$' || true)
    [ ${#mds[@]} -eq 0 ]           || markdownlint-cli2 "${mds[@]}"
    typos "${files[@]}"
    gitleaks git --staged --no-banner --redact
    echo "precommit ok (${#files[@]} files)"

# ---- local deploy -----------------------------------------------------------------

# install or upgrade the chart in the local cluster, running the last pushed mock digest
deploy release="mock":
    helm upgrade --install "{{ release }}" "{{ chart }}" \
        --set image.repository="{{ mock_image }}" \
        --set image.digest="$(cat local/mock-engine.digest)" \
        --set engine.env.STARTUP_DELAY_SECONDS=15 \
        --wait --timeout 3m
    kubectl get pods -l app.kubernetes.io/instance="{{ release }}"

# remove a release installed by `just deploy`
undeploy release="mock":
    helm uninstall "{{ release }}" --ignore-not-found

# ---- helpers --------------------------------------------------------------------

# the Kubernetes version manifests are validated against: read from the pinned
# kind node image so laptops and CI agree without asking a cluster (ADR 0006)
_k8s-version:
    @yq -r '.nodes[0].image' "{{ kind_config }}" | sed -E 's/^.*:v([0-9]+\.[0-9]+\.[0-9]+)@.*$/\1/'

# ---- mock engine ------------------------------------------------------------------

mock_image := "localhost:" + reg_port + "/mock-engine"

# build the mock engine for the local arch and push it; records the digest
mock-push:
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{ mock_image }}:dev"
    docker build -t "$tag" mock-engine
    docker push "$tag"
    digest=$(docker inspect --format '{{{{index .RepoDigests 0}}' "$tag" | cut -d@ -f2)
    echo "$digest" > local/mock-engine.digest
    echo "pushed {{ mock_image }}@$digest"

# run the mock engine in the cluster by digest and exercise every endpoint
mock-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    img="{{ mock_image }}@$(cat local/mock-engine.digest)"
    kubectl delete pod mock --ignore-not-found >/dev/null
    kubectl run mock --restart=Never --image="$img" --port=8000 \
        --env STARTUP_DELAY_SECONDS=5 --env TTFT_MS=100 --env TPOT_MS=10
    kubectl wait pod/mock --for=condition=Ready --timeout=60s
    kubectl port-forward pod/mock 18000:8000 >/dev/null 2>&1 & pf=$!
    trap 'kill $pf; kubectl delete pod mock >/dev/null' EXIT
    sleep 2
    echo "--- health (expect 503 until startup delay elapses, then 200)"
    for _ in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%{http_code}\n" localhost:18000/health; sleep 1; done
    echo "--- streamed completion"
    curl -sN localhost:18000/v1/chat/completions -H 'content-type: application/json' \
        -d '{"model":"mock/mock-8b","stream":true,"max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
    echo "--- admin: force queue depth"
    curl -s -X POST localhost:18000/admin/state -H 'content-type: application/json' -d '{"waiting": 12, "kv_cache_usage": 0.85}'
    echo; echo "--- metrics (vllm:* only)"
    curl -s localhost:18000/metrics | grep '^vllm:' | grep -v '_bucket'
