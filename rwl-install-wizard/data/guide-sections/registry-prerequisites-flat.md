### Registry prerequisites (flat / virtual repository `<FLAT_PREFIX>`)

You chose a FLAT layout, so every image is fronted by the single prefix
`<FLAT_PREFIX>`. Your registry admin must stand up ONE aggregating repository (a
GAR virtual repo, a JFrog virtual repo, or a single flat repo) at that prefix that
resolves all of the upstream sources below.

**The virtual/flat repo `<FLAT_PREFIX>` must aggregate these upstreams:**

| Upstream source | What it provides | Boundary-2 credential |
|---|---|---|
| `docker.io` | Bitnami/HashiCorp/Neo4j/Qdrant/SeaweedFS subchart images | Docker Hub login recommended (dodge anonymous rate limits) |
| `ghcr.io` | RunWhen-contrib + berriai images | none for public RunWhen images |
| `us-docker.pkg.dev/runwhen-self-hosted` | RunWhen first-party platform images | **PRIVATE — attach the RunWhen-provided source-GAR key** |
| `registry.suse.com` | bci-base (helm-test image only) | none |

- **Registry/platform admin** creates the aggregating repo and (Boundary 2) attaches the upstream creds above. First-party RunWhen images will not resolve through `<FLAT_PREFIX>` until the RunWhen source-GAR key is attached to the member repo.
- **Cluster admin** sets up Boundary-1 pull auth (see the registry pull-auth section — either Workload Identity or the image-pull Secret).

**Pre-flight check:** after the repo exists and Boundary-1 auth is set, run the image render-gate in the install section; every image line must start with `<FLAT_PREFIX>`.
