# 0006. CI runs the same checks as a laptop, from the flake

Status: proposed, 2026-09-22

## Context

ADR 0001 says every contributor and CI job gets identical tool versions from
`flake.lock`. No CI existed, so the second half of that was untested. Part 2
adds a Helm chart with tests that run without a cluster, and those tests
only prevent regressions if something runs them on every change.

Options considered: GitHub Actions with the upstream `setup-helm`,
`setup-kubectl` style actions (a second place to pin versions, which will
drift from the flake); GitHub Actions entering the flake's dev shell; a
self-hosted runner with Nix preinstalled.

## Decision

GitHub Actions, in `.github/workflows/ci.yml`, on every push to `main` and
every pull request. Two jobs:

- `check` installs Nix and runs `nix develop .#ci -c just check`: formatting
  checks (ruff, nixfmt, `just --fmt`), linters (ruff, statix, deadnix,
  hadolint, yamllint, markdownlint, actionlint, typos, gitleaks, shellcheck
  on every bash recipe in the justfile), then `helm lint`,
  `helm template | kubeconform`, and `helm unittest`. It is the same recipe a
  laptop runs.
- `mock-image` builds `mock-engine/` with Docker, starts it, and checks that
  `/health` reaches 200 and `/metrics` contains the vLLM series names. No
  Kubernetes involved.

Supporting changes:

- `flake.nix` gains a `ci` dev shell containing only what `just check`
  needs (helm with plugins, kubeconform, just, yq, jq, and the linters). The
  default shell keeps everything; the CI shell exists so the job does not
  download k9s, argocd, grafana-loki and the rest on every run.
- A git pre-commit hook, installed once per clone with `just hooks`, runs
  `just precommit`: the formatters in check mode and the file-scoped linters
  on staged files only, plus gitleaks on the staged diff. It runs inside
  the `ci` shell when the tools are not already on `PATH`. It rewrites
  nothing; `just fmt` is the explicit way to reformat. The hook is a
  convenience, not a gate: CI runs the full set on every push regardless.
  This is plain git and `just` rather than the pre-commit framework or
  git-hooks.nix, so there is no second place that pins tool versions.
- `just _k8s-version` no longer asks a running cluster. It reads the
  Kubernetes version out of the pinned kind node image in
  `local/kind-config.yml`, so kubeconform validates against the same
  version on a laptop and in CI, and the version to validate against is
  pinned in the repo rather than discovered at runtime.
- Actions are pinned to commit SHAs, not tags, consistent with the
  no-`latest` rule for images and tools.

## Consequences

A change that breaks the chart's lint, schema validation, or unit tests
fails the pull request. Tool versions cannot differ between CI and a laptop
because both read `flake.lock`.

The Nix install adds roughly 30 seconds to each run; the store is cached
between runs with `cache-nix-action`.

Nothing in CI runs a kind cluster, so `just smoke` and `just mock-smoke` are
still laptop-only. GitHub runners are amd64 and local builds are arm64
(ADR 0005); the mock's base image is pinned by its multi-arch index digest,
so the `mock-image` job builds natively on amd64 without emulation.

## Revisit when

Part 4 introduces multi-arch builds and a cloud tier, at which point a kind
cluster in CI (or the ephemeral cloud tier) should run the in-cluster smoke
tests too. Or when a policy check (conftest, kyverno) has something to
check, which adds a third job.
