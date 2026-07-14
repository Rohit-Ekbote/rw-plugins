# Design: orthogonal `routing-mode` axis (Gateway API support)

Date: 2026-07-14
Status: approved (maintainer), pending implementation + verification gate

## Problem

Chart `runwhen-platform` 0.2.58 added Gateway API support (commit `a85d170`):
setting `ingress.type: "gateway"` makes the chart render `Gateway` + `HTTPRoute`
resources instead of `Ingress`. The catalog's `gatewayApi` option predates the
feature — it emits only `global.domain` and touches no `ingress.*`, so a wizard
user who picks it gets a kit that renders neither Ingress nor Gateway. The
option's label is a promise the emit does not keep.

The drift detector (`detect-drift.sh`) is structurally blind to this: `global.domain`
renders green, there is no renamed key, and the chart has no `{{ fail }}` on an
empty `gatewayClassName`. A brand-new capability with a stub option produces no
finding.

`cluster-shape` currently conflates two orthogonal decisions in one single-select
axis: TLS certificate source (`clusterIssuer` / `issuer` / `byoSecret`) and
routing mode (`gatewayApi`).

## Decision

Split routing into its own orthogonal single-select axis `routing-mode`. TLS
source stays in `cluster-shape`. The chart shares `ingress.tls.*` across both
routing modes, so the axes are cleanly independent.

## Changes

### New axis `routing-mode` (single-select, inserted after `cluster-shape`)

- **`ingressRouting`** — param `ingressClass` (required) →
  `ingress: {enabled: true, type: ingress, className: "<INGRESS_CLASS>"}`;
  `prereqs: [ingress-controller]`, `guide_sections: [ingress-tls]`.
- **`gatewayClassRouting`** — chart-managed Gateway; param `gatewayClass` (required) →
  `ingress: {enabled: true, type: gateway, gateway: {gatewayClassName: "<GATEWAY_CLASS>"}}`;
  `prereqs: [gateway-api]`.
- **`gatewayExistingRouting`** — existing Gateway; params `gatewayName` +
  `gatewayNamespace` (required) →
  `ingress: {enabled: true, type: gateway, gateway: {existingGateway: {name: "<GATEWAY_NAME>", namespace: "<GATEWAY_NAMESPACE>"}}}`;
  `prereqs: [gateway-api]`.

All three overlay into `values-cluster.yaml`.

### `cluster-shape` becomes TLS-source-only (+ `domain`)

- Delete the `gatewayApi` option.
- From `clusterIssuer` / `issuer` / `byoSecret`: remove the `ingressClass` param
  and the `ingress.enabled` / `ingress.className` emits (moved to `ingressRouting`);
  drop `ingress-controller` from their `prereqs` (routing concern now). Keep
  `ingress.tls.*` (+ the issuer's `ingress.annotations` cert-manager annotation),
  `global.domain`, `guide_sections`, `known_issues`.

### Re-key the ingress-only dependency

`ingress-snippets` (nginx snippets) applies only to Ingress. Update its
`dependsOn` comment in `knob-catalog.yaml` and the matching prose in
`skills/rwl-install/SKILL.md` from "cluster-shape is an Ingress option" to
"routing-mode is `ingressRouting`".

### Rewrite `data/prerequisites/gateway-api.md`

Currently documents the stub ("does NOT emit any ingress.* config"). Rewrite:
the chart now emits `ingress.type=gateway` and creates the Gateway + HTTPRoutes
(class-managed) or attaches to an existing Gateway; operator still needs Gateway
API CRDs + a GatewayClass. Note the caveat: `clusterIssuer` TLS + Gateway mode
relies on cert-manager's Gateway-API support being enabled.

## Verification gate (must be green before hand-off)

- `catalog-lint.sh` clean (labels present; `gateway-api.md` referenced by the two
  gateway options → no orphan; `ingress-controller.md` referenced by `ingressRouting`).
- `run-all.sh` green modulo the pre-existing known neo4j-external red.
- Re-run `detect-drift.sh`: the three routing options render in isolation
  (`global.domain` defaults to `example.com`), no new findings.
- New render+value-at-consumer test: gateway mode renders a `Gateway` whose
  `gatewayClassName` equals the operator input, plus HTTPRoutes. Closes the blind
  spot that hid the stub.

## Out of scope (YAGNI)

Per-service HTTPRoute host overrides, gateway listener port customization,
multi-Gateway topologies.

## Not done here

Never commits; maintainer reviews and commits. Plugin version bump
(`plugin.json` patch) + `marketplace.json` sync are the maintainer's to make
after review, consistent with the rwl-catalog-update workflow.
