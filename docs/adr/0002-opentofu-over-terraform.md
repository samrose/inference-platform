# 0002. Use OpenTofu instead of Terraform

Status: accepted, 2026-09-18

## Context

Infrastructure will be defined in HCL. Terraform moved to the Business
Source License in 2023; OpenTofu is the open-source fork under the Linux
Foundation and is a drop-in replacement for the subset of features this
repo uses.

## Decision

OpenTofu (`tofu`) is the IaC tool. Directory names, lockfile name
(`.terraform.lock.hcl`), and state format are unchanged, so the code reads
as Terraform to anyone who knows it.

## Consequences

No license ambiguity in a public repo. Providers come from
`registry.opentofu.org`, which mirrors everything needed here. CI uses
`opentofu/setup-opentofu`.

Some tutorials and vendor docs assume Terraform; the differences that matter
for this repo are the binary name and the registry.

## Revisit when

A provider or feature this repo needs exists only on the HashiCorp side.
