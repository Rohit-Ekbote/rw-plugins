# Design: coverage-gap detection in rwl-catalog-update

Date: 2026-07-14
Status: approved (maintainer), implemented + verified

## Problem

`detect-drift.sh` only checks that the catalog's EXISTING options still
render/validate. A brand-new chart capability the catalog does not model yet
produces no finding at all: `helm template` of the existing options stays green.
Gateway API (chart 0.2.58: `ingress.type=gateway` + a new `templates/gateway/`
subsystem) shipped entirely invisibly to the detector — the catalog's stub
`gatewayApi` option rendered fine, so nothing flagged the unmodeled feature.

## Decision

Add a third baseline-diff check, `check_coverage`, of the same shape as the
existing `check_validators` / `check_fails`: extract the chart's *capability
surface*, diff against a committed `capabilities.baseline`, emit a needs-decision
`coverageGap` finding for anything new.

Chosen over a catalog-aware (baseline-free) matcher and a values-example diff:
the baseline model matches the detector's established idiom and the
maintainer-acknowledgement workflow, and both extracted signals below would have
caught Gateway API (a values-example diff would not — no example sets
`ingress.type: gateway`).

## Extracted signals (`extract-capabilities.rb`)

Sorted, de-duplicated, one per line:

- `disc:<valuesPath>=<literal>` — a feature discriminator: a `.Values.<path>` a
  template `eq`/`ne` conditional compares against a string literal (mode/type/kind
  switch), including the `| default "x"` branch value. ~10 today
  (`ingress.type`, `redis.architecture`, `secrets.method`).
- `dir:<name>` — a `templates/<name>/` subsystem (feature area). ~37 today.

Pure Ruby 2.6, no gems. Per-line matching of the `eq/ne (.Values.X …) "LIT"` form
the chart uses (documented limitation, mirrors `extract-fails.rb`).

## Baseline semantics

`capabilities.baseline` is a "seen as of chart X" snapshot (like
`validators.baseline`), seeded from 0.2.61 — so it already contains
`disc:ingress.type=gateway` + `dir:gateway` (now modeled by the `routing-mode`
axis). Only capabilities added in a *future* chart get flagged. `check_coverage`
sorts BOTH operands through shell `sort -u` before `comm -13`, avoiding the
locale-collation pitfall the `fails` check documents.

## Resolution (SKILL.md)

New `kind: coverageGap` in the needs-decision walk: investigate the capability,
then either MODEL it (a new option/axis, maintainer-approved — exactly how the
`routing-mode` axis was added) or ACKNOWLEDGE it by regenerating the baseline:
`ruby extract-capabilities.rb <chart>/templates > capabilities.baseline`.
A friction-classes note records that the detector now surfaces this class, and
that baseline re-seeding is the moment to review existing-but-unmodeled switches.

## Tests (`tests/test-detect-drift.sh`, +7)

- A fixture chart with a new `templates/zoo/` + `eq .Values.zoo.mode "safari"`
  flags `dir:zoo` and `disc:zoo.mode=safari`; a baselined subsystem (`papi`) is
  NOT re-flagged.
- Extractor captures both the comparison and `| default` literals of the exact
  Gateway-API guard, plus the template dir.
- A chart reconstructed from the baseline yields zero `coverageGap` (clean
  against itself).

## Scope

Maintainer-side `.claude/skills/rwl-catalog-update/` only — does NOT touch the
shipped `rwl-install-wizard/` plugin, and never commits. Separate from PR #1.

## Out of scope (YAGNI)

Boolean `enabled` toggles (too noisy), nested/computed discriminators, catalog-
aware auto-matching.
