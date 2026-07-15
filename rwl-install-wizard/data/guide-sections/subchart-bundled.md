### Bundled datastores (all-in-cluster)

The chart deploys six bundled subchart components by default — five datastores plus
SeaweedFS (object storage, covered by the `object-storage` axis separately):

| Subchart | Condition key | Role |
|---|---|---|
| `bitnami/postgresql` | `postgresql.deploy: true` | Platform state (users, workspaces, migrations) — **production: prefer `kind: spilo`** |
| `bitnami/redis` | `redis.deploy: true` | Celery broker + Django cache (rebuildable) |
| `neo4j/neo4j` | `neo4j.deploy: true` | Workspace topology graph (rebuildable) |
| `hashicorp/vault` | `vault.deploy: true` | Secrets backend (initialised by `vault-init` Job) |
| `qdrant/qdrant` | `qdrant.useSubchart: true` | Vector store for embeddings (rebuildable) |

Source: `Chart.yaml` lines 39–68.

**Workstation prep — vendor the subcharts before install (REQUIRED).** The
`runwhen-platform` chart is thin: some or all of these subcharts are not present
in its `charts/` directory as shipped. A `helm template`/`helm install` fails
with `found in Chart.yaml, but missing in charts/ directory: neo4j, vault` (or
similar) until you vendor them on the install workstation:

```bash
# Re-resolve from your registered Helm chart-repo aliases and rewrite Chart.lock:
helm dependency update ./runwhen-platform
# OR vendor exactly what the existing Chart.lock already pins (no re-resolve):
helm dependency build ./runwhen-platform
```

Use `update` for a first install or when you point aliases at your own chart repo
(air-gap); `build` is fine when `Chart.lock` is already correct and you only need
the tarballs pulled. Verify all six appear:

```bash
ls ./runwhen-platform/charts/   # postgresql redis neo4j vault qdrant seaweedfs
```

> **Air-gap:** the mirror must hold **every** bundled subchart's images — including
> `neo4j` and `vault`, which are easy to miss because they are `deploy: true` by
> default. Their image tags are pinned in `values-registry.yaml`; reconcile them
> against your resolved `Chart.lock` (see the chart-version section). Chart-repo
> alias registration for the air-gap case is covered in the subchart alias
> mirroring section.

**PostgreSQL mode selector.** The chart has three PG backends:
`kind: spilo` (default, production — Patroni + WAL-G, no CRDs),
`kind: bundled` (bitnami subchart, dev/lab only, single pod, no HA, no backups — see known issues),
`kind: external` (point at managed Postgres).
`postgresql.deploy: true` is the legacy flag for `kind: bundled`; when `kind` is set it takes precedence.

Source: `values.yaml` lines 594–612.

**Start-up dependency chain.** Clean installs must proceed in this order:

```
vault-init Job (initialises + unseals Vault)
    ↓
migration-controllers (wait-for-vault init container polls /v1/sys/health until 200)
    ↓  (also wait-for-db-bootstrap: Postgres role + DB must exist)
papi / agentfarm / usearch (wait-for-migrations polls /ready — NOT /health)
```

Three migration controllers run in parallel once Vault is ready:
`rw-migration-controller` (core schema),
`rw-agentfarm-migration-controller` (agentfarm schema),
`rw-usearch-migration-controller` (usearch schema).

Gating rule: migration-controller dependents MUST poll `/ready` (HTTP 200 = Alembic at head),
not `/health` (HTTP 200 = controller process alive). Using `/health` was the root cause of
INSTALL-FRICTIONS §34; the fix is chart-side and shipped.

Source: INSTALL-FRICTIONS §32 (vault race, resolved 2026-05-18) and §34 (db-init race, resolved 2026-05-25).
