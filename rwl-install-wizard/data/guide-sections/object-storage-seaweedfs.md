### Bundled SeaweedFS object storage

SeaweedFS is the chart's default S3 backend (Apache 2.0, namespace-scoped, no
CRDs, no ClusterRole). It exposes the S3 API on port 8333. All platform S3
consumers (workspace uploads, Mimir blocks/ruler/alertmanager, presigned URLs,
Postgres WAL-G backups, Vault backups) use the same access key wired through
`objectStorage.accessKey` / `objectStorage.secretKey`.

**Key values set by this option:**

```yaml
objectStorage:
  kind: seaweedfs
seaweedfs:
  deploy: true
```

The chart generates an `identities.json` Secret (`<release>-seaweedfs-identities`)
and wires it to `seaweedfs.s3.existingConfigSecret`. The access and secret keys
in `platform-secrets` and the SeaweedFS identities Secret are generated in
lockstep on first install to avoid the Access Denied mismatch (see known issue
`seaweedfs-s3-access-denied`).

> **Release-name coupling — handled for you.** The SeaweedFS identities Secret
> name is derived from the chart fullname (`.Release.Name`, or `fullnameOverride`
> if set), and `runwhen.objectStorage.validate` fail-fasts at template time
> unless `seaweedfs.s3.existingConfigSecret` matches it exactly. So the kit pins
> **`fullnameOverride: <RELEASE_NAME>`** in `values-storage.yaml` alongside
> `existingConfigSecret: <RELEASE_NAME>-seaweedfs-identities`. This makes the
> install work under **any** `helm install <name>` — the derived secret name
> stays `<RELEASE_NAME>-seaweedfs-identities` regardless. In the intended path
> (you install under `<RELEASE_NAME>`) it changes nothing. If you deliberately
> want resource names to track a *different* release name, drop the
> `fullnameOverride` line **and** install under exactly `<RELEASE_NAME>`, or
> re-run the wizard with the release name you will actually use.

**Buckets provisioned automatically** (via the chart-managed bucket-init Job):
`shared-workspace`, `mimir-blocks`, `mimir-ruler`, `mimir-alertmanager`,
`agentfarm-artifacts`, `postgres-backups`, `vault-backups`.

_Source: values.yaml `objectStorage` block (lines 1842–1944); INSTALL-FRICTIONS.md §22._
