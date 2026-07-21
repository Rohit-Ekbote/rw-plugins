# Design: registry-routing knob enhancements (layout × auth × population + verbose prereqs)

Date: 2026-07-17
Status: approved (maintainer), pending implementation + verification gate

## Problem

The `registry-routing` axis offers only two options: `connected` (no mirror) and
`mirrored-per-upstream` (per-source, path-preserving, explicit-mirror-shaped,
always emits pull-secret keys). Measured against the "RunWhen-Platform Registry
Overlay Interviewer" reference spec — which models registry redirection as three
orthogonal axes — that single diagonal leaves three real coverage gaps, plus a
prerequisites gap:

1. **No FLAT layout.** A single-prefix or virtual-repo registry (GAR virtual repo,
   JFrog virtual repo — arguably the most common cloud case) is served by the
   chart's `registryOverride` knob, which the catalog deliberately removed
   (`MISSED-1`). That removal conflated "`registryOverride` is wrong" with
   "`registryOverride` is wrong *for a per-source mirror*." For a genuinely flat
   registry it is the correct mechanism.

2. **No Workload-Identity auth path.** The mirror emit always wires pull-secret
   references (`images.pullSecrets`, `global.imagePullSecrets`, neo4j/qdrant
   `imagePullSecrets`, `ccCatalog.auth.dockerconfigjsonSecret`). GKE + GAR with
   Workload Identity wants none of them; when `pullSecretName` is blank today we
   emit invalid empty `name: ""` references.

3. **Population half-modeled.** The option advertises both pull-through cache and
   explicit air-gap mirror, but the runbook (`airgap-image-manifest.md`) is
   written entirely for explicit mirroring. A cache operator pushes nothing; the
   responsibilities differ.

4. **Thin prerequisites.** The generated prereqs do not spell out, in the
   operator's own values, the remote repos they must have created, the pull
   secret they must have created, or the Boundary-2 upstream credentials
   (including the private RunWhen source-GAR key).

### Ground truth: what `registryOverride` does (verified on chart 0.2.61)

`helm template … --set registryOverride=<prefix>` on 0.2.61 resolves to:

- **Reached AND flattened** (source path dropped, host replaced): all first-party
  (`backend-services`, `agent-farm`, `runner-control`, `webhooks-service`,
  `usearch`, `ui`, `shared-services`), the ghcr first-party (`cc-catalog-svc`,
  `cortex-tenant`, `runwhen-platform-mcp`), `images.llmGateway`, utility
  (`library/busybox`, aux `hashicorp/vault:1.21.2` via `vaultClient`), and the
  wrapper subcharts that honor the override (`spilo-17`, `grafana/mimir`,
  `edoburu/pgbouncer`, bundled `bitnamilegacy/postgresql`). First-party flatten to
  `<prefix>/<name>`; wrapper subcharts to `<prefix>/<repo>`.
- **NOT reached** (still public): `redis`, `neo4j`, `vault:2.0.3` (server),
  `qdrant`, `seaweedfs`, `bci-base` — the pure subcharts.

This confirms: FLAT = `registryOverride` + the same Part-2 subchart keys we
already emit (pointed at the flat prefix). Its manifest push targets differ from
per-source (first-party flattened vs path-preserved), which is exactly why the two
layouts are separate worlds each needing their own manifest — and why FLAT with
its own manifest does not re-open `MISSED-1`.

## Decision

Split the registry concern into three orthogonal axes. Layout owns the registry
re-pointing keys only; auth owns Boundary-1 pull auth (and is the mechanism that
conditionally omits pull-secret keys — Workload Identity contributes nothing);
population owns the runbook/prereq framing only. The emit engine already
deep-merges every selected option's `emits:` into the target overlay, so an auth
option that only *adds* pull-secret keys composes correctly with the layout emit
without any engine change. No key-removal capability is required.

## Changes

### Axis 1 — `registry-routing` becomes LAYOUT (single-select)

Options overlay into `values-registry.yaml`. Layout emits carry registry
re-pointing **only** — no pull-secret keys (those move to `registry-auth`).

- **`connected`** — unchanged (`emits: {}`).
- **`mirrored-per-upstream`** — unchanged per-source emit, **minus** the
  pull-secret keys (`images.pullSecrets`, `global.imagePullSecrets`,
  `neo4j.image.imagePullSecrets`, `qdrant.image.imagePullSecrets`,
  `ccCatalog.auth.dockerconfigjsonSecret`), which relocate to `registry-auth`.
  `neo4j.disableLookups: true` STAYS here (see MISSED-10 note below). Param
  `pullSecretName` moves to `registry-auth`; `registryHost` + `helmMirrorUrl`
  stay. `guide_sections` gains `registry-prerequisites` (Part 4) and keeps its
  existing `airgap-image-manifest` (the per-source push list); the cache/explicit
  framing is contributed by `registry-population`.
- **`flat-mirror`** (new) — param `flatPrefix` (required). Emits:
  - `registryOverride: "<FLAT_PREFIX>"` (reaches first-party + utility + wrapper
    subcharts, flattened).
  - Part-2 subchart keys for the pure subcharts (redis, neo4j `customImage`,
    vault `server`, qdrant, seaweedfs, metricstore, qdrant `chartTests` bci) — same
    shapes as per-source but pointed at `<FLAT_PREFIX>`, path-preserved. Keeps
    `neo4j.disableLookups: true`.
  - The `x-airgap-pinned-tags-notice` block (subcharts are still hard-pinned:
    neo4j 5.26.28, vault 2.0.3, bci-base 15.7 — same values as per-source).
  - No pull-secret keys (auth axis owns them).
  - `guide_sections: [registry-prerequisites, airgap-image-manifest-flat,
    chart-version, helm-install-command]`. Subchart vendoring is covered by the
    universal `helm dependency` step already in `subchart-bundled`; a flat
    chart-repo alias is out of scope for v1 (operator registers Helm aliases
    manually, same as the blank-`helmMirrorUrl` per-source path).

The layout question must disambiguate flat vs per-source concretely: "Do all
images sit under ONE prefix / a virtual repository, or is there a separate repo
per upstream source?"

### Axis 2 — `registry-auth` (new, single-select, `dependsOn`: layout is a mirror)

Overlays into `values-registry.yaml`. Skipped when `registry-routing=connected`.

- **`workload-identity`** — `emits: {}`;
  `guide_sections: [registry-auth-workload-identity]` explaining GKE Workload
  Identity / node-SA `artifactregistry.reader`, no secret to create.
- **`pull-secret`** — param `pullSecretName` (required in this option);
  `guide_sections: [registry-auth-pull-secret]` (the `kubectl create secret
  docker-registry` template; secret-free, `<PLACEHOLDER>` creds only). Emits the
  relocated pull-secret keys:
  - `images.pullSecrets: [{name: "<PULL_SECRET_NAME>"}]`
  - `global.imagePullSecrets: [{name: "<PULL_SECRET_NAME>"}]`
  - `ccCatalog.auth.dockerconfigjsonSecret: "<PULL_SECRET_NAME>"`
  - `neo4j.image.imagePullSecrets: ["<PULL_SECRET_NAME>"]`
  - `qdrant.image.imagePullSecrets: [{name: "<PULL_SECRET_NAME>"}]`

**MISSED-10 handling.** `neo4j.disableLookups: true` is required whenever
`neo4j.image.imagePullSecrets` is set, and is a harmless no-op otherwise. It stays
in the *layout* emit (always on) so Workload-Identity overlays (no
`imagePullSecrets`) still carry it. Both auth modes must be render-verified: WI =
`disableLookups: true` + no `imagePullSecrets` (renders clean); pull-secret =
`disableLookups: true` + `imagePullSecrets` (current behavior).

### Axis 3 — `registry-population` (new, single-select, `dependsOn`: layout is a mirror)

No emit — contributes guide sections only. Skipped when `connected`.

The image **manifest** itself lives on the LAYOUT option (per-source →
`airgap-image-manifest`; flat → `airgap-image-manifest-flat`), because the push
targets are a function of layout, not population. Population contributes only the
framing that tells the operator what to DO with that manifest — avoiding a
cross-axis conditional the static `guide_sections` lists cannot express.

- **`cache`** — `guide_sections: [registry-population-cache]`. Admin creates
  remote/proxy repos once; registry needs outbound access to upstreams; nothing to
  push (the manifest is then only a coverage checklist, not a push list).
- **`explicit-mirror`** — `guide_sections: [registry-population-explicit]`. Every
  image pulled/tagged/pushed ahead of time; this section points at the
  layout-provided manifest as the authoritative push list.

### Part 4 — verbose, tokenized prerequisites

New generated guide fragment `registry-prerequisites` (referenced by both mirror
layout options), assembled from the collected values:

- **Remote repos to create**, by canonical name and the upstream each proxies —
  these are the names the overlay actually references, so they are accurate and
  actionable:
  - `docker-dockerhub` → `docker.io` (Docker Hub login recommended to dodge rate
    limits — Boundary-2)
  - `docker-ghcr` → `ghcr.io`
  - `docker-runwhen-self-hosted` → `us-docker.pkg.dev/runwhen-self-hosted`
    (**PRIVATE — attach the RunWhen-provided source-GAR key**, Boundary-2)
  - `docker-suse` → `registry.suse.com` (helm-test only)
  For `flat-mirror`: the virtual/flat repo `<FLAT_PREFIX>` aggregating those
  members.
- **Pull secret to create** — name `<PULL_SECRET_NAME>` in the release namespace.
  Emitted ONLY when `registry-auth=pull-secret`; replaced by a Workload-Identity
  note otherwise.
- **Boundary-2 upstream creds**, per persona (registry/platform admin), including
  the RunWhen source-GAR key.
- **Population-specific duty** — cache: "mappings exist + registry has egress";
  explicit: "all images pushed, verify against the manifest".

Substitution uses existing `<UPPER_TOKEN>` params (`REGISTRY_HOST`, `FLAT_PREFIX`,
`PULL_SECRET_NAME`). The per-remote canonical names stay convention (not new
params); the section states them as the repos the operator must create, matching
what the overlay references.

## Non-goals

- Per-remote-name customization (operator-typed repo names) — rejected: it would
  re-tokenize every image path in the emit plus the manifest and the regression
  guard, high risk for low marginal value. Canonical names are stated explicitly
  instead.
- Vendor capture (GAR/JFrog/Harbor/ECR) as a chart-affecting axis — the reference
  spec itself says vendor changes wording/runbook, not keys. Out of scope; the
  prereqs cover the vendor-neutral facts.
- Changing the SeaweedFS emit shape to the spec's per-component `image.override` —
  our `global.seaweedfs.image.name` + `image.repository` shape renders correctly on
  0.2.61 (guard-confirmed). Left as a verify-on-future-subchart note, not a change.
- Bundled Bitnami Postgres re-pointing — N/A, the catalog pins `postgresql.kind:
  spilo`.

## Testing / verification gate

- **Render-gate (new coverage)** against the vendored 0.2.61 chart: `helm template`
  each new combination — {flat, per-source} × {WI, pull-secret} — and assert every
  `image:` line lands on the operator prefix (no residual `docker.io` / `ghcr.io` /
  `us-docker.pkg.dev` / `registry.suse.com`), and that WI overlays contain zero
  pull-secret keys while pull-secret overlays contain them.
- **`test-airgap-registry.sh`** extended: a flat overlay fixture and a WI
  (secret-free) fixture; keep the pinned-tag lockstep assertions green (pins are
  unchanged: neo4j 5.26.28 / vault 2.0.3 / bci 15.7 in both layouts).
- **New expected fixtures** under `tests/fixtures/expected/` for the flat and WI
  shapes; regenerate as needed.
- **`catalog-lint`** clean (every `guide_sections`/`prereqs` id has a backing
  `.md`; no orphans; `dependsOn` well-formed).
- **`RWL_CHART_PATH=<0.2.61> tests/run-all.sh`** green apart from the pre-existing
  accepted known-red neo4j chart-bug test.
- **`SKILL.md`** updated to describe the three axes, `dependsOn` skips, and the
  auth/population interview steps. (Structural interview changes are
  maintainer-approved; the skill file itself is edited under the normal design
  gate, NOT by `/rwl-catalog-update`.)

## Sequencing

One spec; the implementation plan phases it to land lower-risk work first:

1. **`registry-auth` axis** — extract pull-secret keys out of
   `mirrored-per-upstream`, add WI/pull-secret options, keep `disableLookups` in
   layout. Render-verify per-source × {WI, pull-secret}.
2. **`registry-population` axis + verbose `registry-prerequisites`** — guide work;
   wire cache/explicit framing and the tokenized prereqs.
3. **`flat-mirror` layout option + `airgap-image-manifest-flat`** — the heaviest,
   with its own render-gate proving the flattened output matches the flat manifest.

Each phase ends green on `catalog-lint` + the suite before the next begins.
