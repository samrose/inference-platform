# 0005. Local images are built single-arch

Status: accepted, 2026-09-19

## Context

Development happens on Apple Silicon; the kind nodes are therefore arm64.
Cloud GPU nodes are amd64. The mock engine's base image is pinned by its
multi-arch index digest, so the same `FROM` line resolves correctly on
either architecture, but the built image itself is only for the host.

## Decision

`just mock-push` builds for the host architecture and records the resulting
digest in `local/mock-engine.digest`. No multi-arch build yet.

## Consequences

Fast local builds with no emulation. The digest recorded locally is
arm64-only and cannot be used on the cloud tier.

## Revisit when

The cloud tier exists (step 3). At that point builds switch to
`docker buildx --platform linux/amd64,linux/arm64`, the recorded digest
becomes the index digest, and this record is superseded.
