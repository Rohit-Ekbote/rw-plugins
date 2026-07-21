### Registry prerequisites (for `<REGISTRY_HOST>`)

Before installing, the following must already exist on your registry. These are
the exact repositories the generated overlays reference — create them under the
names shown (rename in the overlay only if your registry uses different ones).

**Remote/source repositories to create** (each proxies or holds one upstream):

| Repo (canonical name) | Upstream it maps to | Boundary-2 credential |
|---|---|---|
| `docker-dockerhub` | `docker.io` | Docker Hub login recommended (dodge anonymous rate limits) |
| `docker-ghcr` | `ghcr.io` | none for public RunWhen images |
| `docker-runwhen-self-hosted` | `us-docker.pkg.dev/runwhen-self-hosted` | **PRIVATE — attach the RunWhen-provided source-GAR key** |
| `docker-suse` | `registry.suse.com` | none (helm-test image only) |

- **Registry/platform admin** creates these repos and (Boundary 2) attaches the upstream creds above. The `docker-runwhen-self-hosted` repo will not resolve any RunWhen first-party image until the RunWhen source-GAR key is attached.
- **Cluster admin** sets up Boundary-1 pull auth per the registry pull-auth section below (Workload Identity, or an image-pull Secret, depending on the auth mode selected for this kit).

**Pre-flight check:** after the repos exist and Boundary-1 auth is set, run the
image render-gate in the install section; every image line must start with
`<REGISTRY_HOST>`.
