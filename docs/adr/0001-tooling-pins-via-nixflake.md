# 0001. Pin developer tooling with a Nix flake

Status: accepted, 2026-09-18

## Context

The repo depends on a dozen CLIs (kubectl, helm and its plugins, kind,
kubeconform, opentofu, argocd, just, python, uv). Version drift between
contributors, or between a laptop and CI, is a common source of "works on my
machine" failures, and it undermines the claim that the cluster is a function
of a commit.

Options considered: asdf/mise with `.tool-versions`, a devcontainer, Homebrew
with a Brewfile, a Nix flake.

## Decision

A `flake.nix` provides a dev shell with every CLI pinned, and `flake.lock` is
committed. Nix is used for tooling only. Images are built with Docker, charts
with Helm, infrastructure with OpenTofu. Nothing in the repo is built with
Nix, and no host runs NixOS.

Docker's daemon is the one dependency outside the flake, because it is
host-level and platform-specific.

## Consequences

Every contributor and CI job gets identical tool versions from one file.
Bumping a tool is a reviewable diff to `flake.lock`.

Contributors need Nix installed. A `.devcontainer` or `.tool-versions` can be
added as a fallback; the flake stays the source of truth.

## Revisit when

A required tool is not packaged in nixpkgs and packaging it is more work
than the pinning is worth, or contributors consistently refuse to install
Nix.
