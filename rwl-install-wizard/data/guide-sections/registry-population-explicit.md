### Registry population — explicit mirror (air-gap)

You selected explicit mirror. **Every image must be pushed to your registry before
install** — nothing loads lazily. **Responsibilities:**

- **Mirror operator (connected host, holds Boundary-2 creds incl. the RunWhen
  source-GAR key):** for each entry in the image manifest in this guide, `pull →
  tag → push` to the matching repo, preserving the repository path shown.
- **Operator:** apply the overlay only AFTER the manifest is fully pushed.
- The manifest in this guide is the authoritative **push list**. Any image left on
  a public host after the pre-flight render check is one you have not mirrored — it
  will `ImagePullBackOff`. Fix it by pushing the image, never by editing values.
