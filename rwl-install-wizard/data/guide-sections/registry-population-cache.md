### Registry population — pull-through cache

You selected pull-through cache. Your registry admin creates each remote/proxy
repository once; images then load lazily on first pull. **Responsibilities:**

- **Registry/platform admin:** the remote repos on `<REGISTRY_HOST>` must exist and
  each must have outbound (Boundary-2) access to its upstream, with upstream creds
  attached where required (see the Registry prerequisites section — the RunWhen
  source-GAR repo is PRIVATE and needs the RunWhen-provided key).
- **Operator:** nothing to push. The image manifest in this guide is a **coverage
  checklist** — use it to confirm every upstream repo has a matching remote, not a
  push list.
- First pull of an image the remote can't resolve fails as `ImagePullBackOff`; fix
  the remote mapping / upstream creds, then re-pull.
