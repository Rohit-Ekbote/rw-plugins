### Registry pull auth — Workload Identity (no pull secret)

You selected Workload Identity / node-SA auth, so this kit emits **no**
`imagePullSecrets` anywhere. Boundary-1 (cluster → your registry) is satisfied by
the node identity, not a Kubernetes Secret.

**Cluster admin must ensure**, before install:

- The node pool's (or Workload-Identity) Google service account has
  `roles/artifactregistry.reader` on the project/repository that backs
  `<REGISTRY_HOST>`.
- No `<name>-...` image pull Secret is required or referenced.

If pulls fail with `401`/`403` at `ImagePullBackOff`, the node SA is missing the
reader role — fix the IAM binding, do NOT add a pull secret (re-run the wizard and
pick the pull-secret option if this cluster genuinely needs one).
