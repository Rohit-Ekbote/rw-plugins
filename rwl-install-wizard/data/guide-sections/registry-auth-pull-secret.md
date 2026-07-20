### Registry pull auth — image pull Secret

You selected pull-secret auth, so the kit wires `<PULL_SECRET_NAME>` into
`images.pullSecrets`, `global.imagePullSecrets`, the cc-catalog auth, and the
neo4j/qdrant subcharts. **You must create that Secret yourself** in the release
namespace before install (the wizard never handles secret material):

    kubectl create secret docker-registry <PULL_SECRET_NAME> \
      --namespace <NAMESPACE> \
      --docker-server=<REGISTRY_HOST_ONLY> \
      --docker-username='<USERNAME>' \
      --docker-password='<PASSWORD_OR_TOKEN>' \
      --docker-email='<EMAIL>'

- `<REGISTRY_HOST_ONLY>` is your registry host (the same prefix the overlays use;
  host only — no scheme, no path).
- Fill `<USERNAME>`/`<PASSWORD_OR_TOKEN>` from your registry credentials — these
  are Boundary-1 (cluster → your registry) creds, distinct from the Boundary-2
  upstream creds your registry admin configures.
- The Secret must be of type `kubernetes.io/dockerconfigjson`.
