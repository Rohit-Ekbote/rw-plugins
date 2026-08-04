### Air-gap image manifest — FLAT layout (`<FLAT_PREFIX>`)

You chose a FLAT / virtual-repo layout, so `registryOverride: <FLAT_PREFIX>`
**flattens** first-party and wrapper images (the source path is dropped), while
the pure subcharts keep their repository path under the prefix. Mirror exactly
these targets (preserving each path shown):

```text
# First-party + ghcr first-party + utility + wrapper subcharts (flattened by registryOverride):
<FLAT_PREFIX>/backend-services:2026-08-03.1
<FLAT_PREFIX>/agent-farm:2026-08-03.1
<FLAT_PREFIX>/runner-control:2026-07-29.1
<FLAT_PREFIX>/webhooks-service:2026-08-03.1
<FLAT_PREFIX>/usearch:2026-08-03.1
<FLAT_PREFIX>/ui:2026-08-03.1
<FLAT_PREFIX>/shared-services:2026-08-03.1
<FLAT_PREFIX>/cc-catalog-svc:2026-07-23.3
<FLAT_PREFIX>/cortex-tenant:2026-07-31.1
<FLAT_PREFIX>/runwhen-platform-mcp:2026-07-29.2
<FLAT_PREFIX>/litellm-non_root:v1.88.2            # if llmGateway deployed
<FLAT_PREFIX>/library/busybox:1.36
<FLAT_PREFIX>/spilo-17:17.10-ff07941a             # Postgres server AND the psql client for db-init / migration jobs
<FLAT_PREFIX>/grafana/mimir:3.1.2
<FLAT_PREFIX>/edoburu/pgbouncer:v1.25.2-p0        # if pgbouncer enabled (default on under kind=spilo)

# Pure subcharts (registryOverride does NOT reach these — set via explicit keys, path-preserved):
<FLAT_PREFIX>/bitnamilegacy/redis:8.2.1-debian-12-r0
<FLAT_PREFIX>/library/neo4j:5.26.28-ubi10
<FLAT_PREFIX>/hashicorp/vault:2.0.3               # subchart server (also the init/unseal/backup client since 0.2.68)
<FLAT_PREFIX>/qdrant/qdrant:v1.18.3
<FLAT_PREFIX>/chrislusf/seaweedfs:4.25
<FLAT_PREFIX>/bci/bci-base:15.7                   # helm-test only
```

> Tags track your resolved chart/subchart versions — confirm against `Chart.lock`
> and the chart-version section. The three hard-pinned subchart tags
> (`neo4j 5.26.28-ubi10`, `vault 2.0.3`, `bci-base 15.7`) are the same as the
> per-source manifest. Two images older kits listed are gone: the aux
> `vault 1.21.2` (re-pinned to the server tag in chart 0.2.68) and
> `bitnamilegacy/postgresql` (chart 0.2.74 reuses the Spilo image as the psql
> client) — do not mirror either.

**Validation (run before install):**
```bash
helm template <RELEASE> <CHART_REF> -f values-registry.yaml <other -f overlays> \
  | grep -oE 'image: \S+' | sort -u
```
Every line must start with `<FLAT_PREFIX>`. Any residual `docker.io` / `ghcr.io` /
`us-docker.pkg.dev` / `registry.suse.com` is an image the overlay has not
re-pointed — fix the overlay (or push+map that image), then re-render.
