### Air-gap image manifest (`images-to-mirror.txt`) + pre-seeding

Before the cluster can pull anything, **every** image the chart renders must
already live on your mirror (`<REGISTRY_HOST>`). Produce the exact list from
*your* overlays, then copy each image across.

#### 1. Generate the authoritative list from your overlays (preferred)

The chart ships `image-scripts/fetch-chart-images.sh`. Run it on the install
workstation against the same overlays you install with — it renders the chart
(parent + all five subcharts) and emits `images.txt` (flat, deduped) plus
`images.json`:

```bash
./charts/runwhen-platform/image-scripts/fetch-chart-images.sh \
  -f charts/runwhen-platform/values.yaml \
  -f values-registry.yaml \
  -f values-storage.yaml \
  -f values-cluster.yaml \
  -o ./out
cp ./out/images.txt images-to-mirror.txt
```

This is the source of truth — it reflects the exact tags pinned in *your* chart
version, so it never drifts from the baseline table below.

#### 2. Baseline list (fallback, chart `~0.2.x`)

If you cannot render the chart yet, seed from this baseline, then re-verify with
step 1 once you have the chart on disk. Save as `images-to-mirror.txt`
(upstream refs — the left column is what you copy *from*):

```text
# images-to-mirror.txt — upstream refs; mirror each to <REGISTRY_HOST>/<repo>:<tag>
us-docker.pkg.dev/runwhen-self-hosted/platform-images/backend-services:2026-08-03.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/agent-farm:2026-08-03.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/runner-control:2026-07-29.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/webhooks-service:2026-08-03.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/usearch:2026-08-03.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/ui:2026-08-03.1
us-docker.pkg.dev/runwhen-self-hosted/platform-images/shared-services:2026-08-03.1
ghcr.io/runwhen-contrib/runwhen-platform-mcp:2026-07-29.2
ghcr.io/runwhen-contrib/cc-catalog-svc:2026-07-23.3
ghcr.io/runwhen-contrib/cortex-tenant:2026-07-31.1
ghcr.io/berriai/litellm-non_root:v1.88.2
# Spilo is BOTH the Postgres server and the `psql` client for the db-init /
# migration jobs (chart 0.2.74) — one image covers both. Moved off
# ghcr.io/zalando/spilo-17 in 0.2.73.
ghcr.io/runwhen-contrib/spilo-17:17.10-ff07941a
docker.io/library/busybox:1.36
docker.io/hashicorp/vault:2.0.3
docker.io/bitnamilegacy/redis:8.2.1-debian-12-r0
docker.io/grafana/mimir:3.1.2
docker.io/qdrant/qdrant:v1.18.3
docker.io/library/neo4j:5.26.28-ubi10
docker.io/chrislusf/seaweedfs:4.25
docker.io/edoburu/pgbouncer:v1.25.2-p0
# helm-test-only (qdrant test pod) — mirror ONLY if you run `helm test`:
registry.suse.com/bci/bci-base:15.7
```

> Tags track a specific chart revision. `neo4j`, `vault`, `qdrant`, `redis`,
> and `seaweedfs` are pinned by the resolved subchart versions — confirm each
> against your chart (see the chart-version section) or, better, regenerate with
> step 1. The six code-collection images (`rw-*`/`*-c7n-codecollection`) are
> selected dynamically by `cc-catalog-svc` at task time; mirror the current
> dated tag and keep `listRemoteFolderItems` enabled on the ghcr remote.

> **Canonical source for the overlay's hard-pinned tags.** Three tags in this
> baseline — `library/neo4j:5.26.28-ubi10`, `hashicorp/vault:2.0.3` (the subchart
> server), and `bci/bci-base:15.7` — are also emitted as full-value overrides in
> `values-registry.yaml` (and restated in its `x-airgap-pinned-tags-notice`
> block). This baseline is the single source of truth for those three; if you
> change one here, change it in the overlay too. The `-ubi10` suffix on neo4j is
> deliberate — the chart pins the UBI-based build (Red Hat security patches) as
> its default, so mirror `5.26.28-ubi10`, not the Debian-based `5.26.28`. The
> wizard's regression guard asserts overlay and baseline stay identical, so they
> cannot silently drift.
>
> **Vault is now a single tag.** Older kits listed a second
> `hashicorp/vault:1.21.2` for the chart's own vault-binary jobs
> (init/auto-unseal/backup). Chart 0.2.68 re-pinned that client to match the
> subchart server, so `2.0.3` is the only vault tag to mirror.

#### 3. Copy each image to the mirror — PER-UPSTREAM, path-preserving (skopeo)

The generated `values-registry.yaml` uses the per-upstream, path-preserving
model: each image keeps its source path under a per-upstream remote
(`docker-dockerhub`, `docker-ghcr`, `docker-runwhen-self-hosted`, `docker-suse`).
**The push target for every image is exactly the ref the overlay renders** — so
the copy targets below are, by construction, what the cluster will pull. (This is
why the old single-prefix `registryOverride`/flat-mirror model was removed: it
collapsed images to `<mirror>/<repo>`, disagreeing with these push paths →
ImagePullBackOff.)

Map each upstream host to its per-upstream remote and preserve the rest of the
path (rename the `docker-*` remote segments if your mirror named them differently
— keep them identical in `values-registry.yaml` and here):

```bash
to_mirror() {
  ref="$1"; host="${ref%%/*}"; path="${ref#*/}"
  case "$host" in
    us-docker.pkg.dev)               echo "<REGISTRY_HOST>/docker-runwhen-self-hosted/${path}" ;;
    ghcr.io)                         echo "<REGISTRY_HOST>/docker-ghcr/${path}" ;;
    docker.io|registry-1.docker.io)  echo "<REGISTRY_HOST>/docker-dockerhub/${path}" ;;
    registry.suse.com)               echo "<REGISTRY_HOST>/docker-suse/${path}" ;;
    quay.io)                         echo "<REGISTRY_HOST>/docker-quay/${path}" ;;
    *) echo "UNMAPPED-UPSTREAM:$ref" >&2; return 1 ;;
  esac
}
while read -r ref; do
  case "$ref" in \#*|"") continue ;; esac
  dst="$(to_mirror "$ref")" || { echo "no mapping for $ref — add one"; continue; }
  skopeo copy --all "docker://$ref" "docker://$dst"
done < images-to-mirror.txt
```

**Verify overlay == manifest** before installing — every rendered ref must be a
target this loop pushes to:

```bash
helm template <RELEASE> <CHART_REF> \
  -f runwhen-platform/values.yaml -f values-registry.yaml \
  | grep -Eo '(image|customImage): *"?[^" ]+' | awk '{print $2}' | sort -u
# Each line must start with <REGISTRY_HOST>/docker-... and match a to_mirror() target.
```

`crane cp <upstream-ref> <to_mirror-target>` works equally well.

#### 4. Digest-pin for immutable, supply-chain-verifiable installs

Tags are mutable; a re-pushed upstream tag silently changes what you deploy.
For hardened installs, resolve each ref to its `sha256:` digest and pin by
digest in your overlay so the cluster only ever runs the bytes you scanned:

```bash
# Resolve digests once, after mirroring (against the per-upstream target path):
crane digest <REGISTRY_HOST>/docker-dockerhub/library/neo4j:5.26.28-ubi10
#   sha256:abc123...
```

Then pin the resolved digest instead of the tag, e.g.:

```yaml
neo4j:
  image:
    customImage: "<REGISTRY_HOST>/docker-dockerhub/library/neo4j@sha256:abc123..."
vault:
  server:
    image:
      repository: "<REGISTRY_HOST>/docker-dockerhub/hashicorp/vault"
      tag: "sha256:def456..."        # digest form; drops tag-rug risk
```

Record the digest ↔ tag mapping in your change-control system so a re-scan is
reproducible. Re-resolve digests whenever you bump the chart version.
