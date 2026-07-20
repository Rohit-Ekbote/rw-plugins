# Registry-Routing Knob Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the `rwl-install-wizard` registry knob into three orthogonal axes (layout / auth / population) plus verbose tokenized prerequisites, matching the RunWhen-Platform Registry Overlay Interviewer reference spec.

**Architecture:** `registry-routing` becomes LAYOUT (connected / flat-mirror / mirrored-per-upstream), emitting registry re-pointing keys only. A new `registry-auth` axis (dependsOn: a mirror is chosen) owns Boundary-1 pull auth — `workload-identity` emits nothing (the key-omission mechanism), `pull-secret` emits the relocated pull-secret keys, deep-merged into `values-registry.yaml`. A new `registry-population` axis contributes only cache/explicit runbook framing. A new generated `registry-prerequisites` fragment spells out, in the operator's own values, the remote repos, pull secret, and Boundary-2 creds.

**Tech Stack:** YAML catalog (`data/knob-catalog.yaml`), Markdown guide fragments (`data/guide-sections/`, `data/prerequisites/`), Ruby assembler (`lib/build-guide.rb` — HTML only, unchanged), bash test suite (`tests/*.sh`), Helm 3 render-gate against a vendored chart.

## Global Constraints

- **Chart target:** `chartCompat: ">=0.2.37 <0.3"`; render-verify against the vendored **0.2.61** checkout at `$CHART` (see Setup). Pinned subchart tags are unchanged: neo4j `5.26.28`, vault server `2.0.3`, bci-base `15.7`.
- **Emit engine:** deep-merges every selected option's `emits:` into its `overlay:` file. There is NO key-removal; conditional omission is achieved by which option contributes a key.
- **Substitution:** `build-guide.rb` replaces only `<UPPER_SNAKE>` tokens built from answered params (`substitute()`), derived via `screaming(paramId)`. Lowercase/`<your x>` pseudo-tokens render verbatim — never use them for values.
- **Secret-free:** never emit or template a secret value; wire secrets by name only (`existingSecret`/`dockerconfigjsonSecret`/`imagePullSecrets`). Pull-secret guide templates use `<PLACEHOLDER>` creds only.
- **catalog-lint:** every `guide_sections`/`prereqs`/`known_issues` id MUST have a backing `.md`; no orphan `.md` files; inline arrays only (`guide_sections: [a, b]`).
- **Never commit without asking.** Each task ends with a review checkpoint: stage changes, show `git status` + `git diff --stat`, and ASK the maintainer before committing. Structural catalog changes are maintainer-approved.
- **Never edit `skills/rwl-install/SKILL.md` via `/rwl-catalog-update`** — SKILL edits here are under this design gate and are explicit tasks.

## Setup (run once before Phase 1)

```bash
cd /Users/rohitekbote/emdash/worktrees/rw-plugins/emdash/main-for-qna-lcngl
export PLUGIN=$PWD/rwl-install-wizard
export CHART=/private/tmp/claude-501/-Users-rohitekbote-emdash-worktrees-rw-plugins-emdash-main-for-qna-lcngl/7056efe8-9e7a-46f0-ac38-9208fa43fe98/scratchpad/chart-0.2.61/charts/runwhen-platform
# If $CHART is gone, re-create it (isolated worktree at the 0.2.61 tag):
if [ ! -f "$CHART/Chart.yaml" ]; then
  WT=$(dirname $(dirname "$CHART"))
  git -C /Users/rohitekbote/emdash/repositories/rwlight-helm worktree add --detach "$WT" runwhen-platform-0.2.61
  ( cd "$CHART" && helm dependency build )
fi
test -f "$CHART/Chart.yaml" && echo "CHART OK" || echo "CHART MISSING — fix before proceeding"
```

**Green-bar definition (every task's final verification):**
```bash
bash "$PLUGIN/lib/catalog-lint.sh" "$PLUGIN/data/knob-catalog.yaml" "$PLUGIN/data" && echo LINT-OK
RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/run-all.sh" 2>&1 | grep -E "passed, [0-9]+ failed|FAIL:"
```
Expected: `LINT-OK`; every suite `N passed, 0 failed` EXCEPT `airgap-registry`, whose ONLY allowed failure is the known-red `byo: KNOWN neo4jUri consumer red (chart bug neo4j-external-agentfarm-usearch)`.

---

# PHASE 1 — `registry-auth` axis (extract pull-secret keys; add WI)

**Phase invariant:** generating `per-source + pull-secret` must produce a `values-registry.yaml` byte-identical to today's `fixtures/expected/airgap/values-registry.yaml` (the split only moves which axis contributes each key; deep-merge recombines them). `workload-identity` must produce a secret-free overlay.

## Task 1.1: Move pull-secret keys out of `mirrored-per-upstream` into a new `registry-auth` axis

**Files:**
- Modify: `rwl-install-wizard/data/knob-catalog.yaml` (`mirrored-per-upstream` emit + `params`; insert new `registry-auth` axis after `registry-routing`)
- Create: `rwl-install-wizard/data/guide-sections/registry-auth-workload-identity.md`
- Create: `rwl-install-wizard/data/guide-sections/registry-auth-pull-secret.md`

**Interfaces:**
- Produces: axis `registry-auth` with options `workload-identity` (emits `{}`) and `pull-secret` (param `pullSecretName`, emits the pull-secret keys). Token `<PULL_SECRET_NAME>` now originates from the `pull-secret` option's param.
- Consumes: existing `mirrored-per-upstream` emit structure in `values-registry.yaml`.

- [ ] **Step 1: Write the failing test** — append a WI-vs-pull-secret structural assertion to `tests/test-airgap-registry.sh`. Immediately AFTER the existing `== MISSED-1: ... ==` block's `$REG` checks (search for the line `if nocomment "$REG" | grep -qE 'registryOverride'`), add:

```bash
echo "== AUTH: registry-auth axis owns pull-secret keys =="
# The pull-secret keys must NO LONGER be inline on the layout option; they live on
# registry-auth=pull-secret. The layout option must not carry pullSecrets itself.
layout_block="$(option_block mirrored-per-upstream)"
if printf '%s' "$layout_block" | grep -qE 'pullSecrets|dockerconfigjsonSecret|imagePullSecrets'; then
  no "mirrored-per-upstream still carries pull-secret keys inline (should move to registry-auth)"
else ok "mirrored-per-upstream carries no pull-secret keys"; fi
authps_block="$(option_block pull-secret)"
for k in "images:" "pullSecrets:" "imagePullSecrets:" "dockerconfigjsonSecret:"; do
  if printf '%s' "$authps_block" | grep -qF "$k"; then ok "registry-auth=pull-secret emits $k"; else no "registry-auth=pull-secret missing $k"; fi
done
authwi_block="$(option_block workload-identity)"
if printf '%s' "$authwi_block" | grep -qE 'pullSecrets|imagePullSecrets|dockerconfigjsonSecret'; then
  no "workload-identity emits pull-secret keys (must be secret-free)"; else ok "workload-identity is secret-free"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "AUTH|FAIL:"`
Expected: FAIL lines — `registry-auth=pull-secret missing images:` etc. (the axis does not exist yet).

- [ ] **Step 3: Remove pull-secret keys from `mirrored-per-upstream`** in `data/knob-catalog.yaml`. Delete exactly these fragments from that option's emit:
  - Under `global:` → the `imagePullSecrets:` list (`imagePullSecrets:` + its one `- name: "<PULL_SECRET_NAME>"` line).
  - Under `images:` → the `pullSecrets:` list (`pullSecrets:` + its `- name: "<PULL_SECRET_NAME>"` line). Keep `images.registry`, `mcpServer`, `ccCatalog`, `llmGateway`.
  - Under `ccCatalog:` → the `auth:` block (`auth:` + `dockerconfigjsonSecret: "<PULL_SECRET_NAME>"`). Keep `ccCatalog.config`.
  - Under `neo4j.image:` → the `imagePullSecrets:` list (`imagePullSecrets:` + `- "<PULL_SECRET_NAME>"`). **Keep `neo4j.disableLookups: true` and `neo4j.image.customImage`.**
  - Under `qdrant.image:` → the `imagePullSecrets:` list (`imagePullSecrets:` + `- name: "<PULL_SECRET_NAME>"`). Keep `qdrant.disableLookups`, `qdrant.image.repository`, `qdrant.chartTests`.
  - Remove the `pullSecretName` param line from `mirrored-per-upstream.params` (the `{ id: pullSecretName, ... }` line).

- [ ] **Step 4: Insert the `registry-auth` axis** immediately AFTER the `registry-routing` axis closes (after `mirrored-per-upstream`'s last line, before `- id: storage-persistence`). Add:

```yaml
  - id: registry-auth
    title: Registry pull authentication (Boundary 1)
    # dependsOn: applies only when a mirror layout is chosen (flat-mirror or
    # mirrored-per-upstream), NOT connected. SKILL skips this axis under connected.
    question: "How do cluster nodes authenticate to your registry to PULL images? On GKE with a node/Workload-Identity SA that has artifactregistry.reader, no pull secret is needed. Otherwise a dockerconfigjson image pull Secret is required."
    options:
      - id: workload-identity
        label: "Workload Identity / node-SA — GKE node or WI SA has artifactregistry.reader; NO pull secret"
        overlay: values-registry.yaml
        emits: {}
        guide_sections: [registry-auth-workload-identity]
        known_issues: []
      - id: pull-secret
        label: "Pull Secret — a pre-created dockerconfigjson Secret (JFrog/Harbor/ECR/private GAR without WI)"
        overlay: values-registry.yaml
        params:
          - { id: pullSecretName, prompt: "Name of the pre-created Kubernetes image pull Secret (kubernetes.io/dockerconfigjson) in the release namespace (e.g. jcr-pull-secret).", required: true }
        emits:
          global:
            imagePullSecrets:
              - name: "<PULL_SECRET_NAME>"
          images:
            pullSecrets:
              - name: "<PULL_SECRET_NAME>"
          ccCatalog:
            auth:
              dockerconfigjsonSecret: "<PULL_SECRET_NAME>"
          neo4j:
            image:
              imagePullSecrets:
                - "<PULL_SECRET_NAME>"
          qdrant:
            image:
              imagePullSecrets:
                - name: "<PULL_SECRET_NAME>"
        guide_sections: [registry-auth-pull-secret]
        known_issues: []
```

- [ ] **Step 5: Create `data/guide-sections/registry-auth-workload-identity.md`:**

```markdown
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
```

- [ ] **Step 6: Create `data/guide-sections/registry-auth-pull-secret.md`:**

```markdown
### Registry pull auth — image pull Secret

You selected pull-secret auth, so the kit wires `<PULL_SECRET_NAME>` into
`images.pullSecrets`, `global.imagePullSecrets`, the cc-catalog auth, and the
neo4j/qdrant subcharts. **You must create that Secret yourself** in the release
namespace before install (the wizard never handles secret material):

    kubectl create secret docker-registry <PULL_SECRET_NAME> \
      --namespace <RELEASE_NAMESPACE> \
      --docker-server=<REGISTRY_HOST> \
      --docker-username='<USERNAME>' \
      --docker-password='<PASSWORD_OR_TOKEN>' \
      --docker-email='<EMAIL>'

- `<REGISTRY_HOST>` is your registry host (the same prefix the overlays use).
- Fill `<USERNAME>`/`<PASSWORD_OR_TOKEN>` from your registry credentials — these
  are Boundary-1 (cluster → your registry) creds, distinct from the Boundary-2
  upstream creds your registry admin configures.
- The Secret must be of type `kubernetes.io/dockerconfigjson`.
```

- [ ] **Step 7: Run the render-gate — per-source × pull-secret must land every image on the mirror, and × WI must be secret-free.**

Run:
```bash
# pull-secret mode: the existing airgap fixture already represents per-source+pull-secret+explicit.
RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "AUTH|MISSED-1|FAIL:"
```
Expected: all `AUTH:` and `MISSED-1:` lines PASS; only allowed FAIL is the known-red neo4j line.

- [ ] **Step 8: Full green-bar** (Setup block). Expected: LINT-OK; suites green except the known-red neo4j.

- [ ] **Step 9: Review checkpoint (do NOT commit yet).**

Run: `cd /Users/rohitekbote/emdash/worktrees/rw-plugins/emdash/main-for-qna-lcngl && git add -A && git status --porcelain && git diff --cached --stat`
Then ASK the maintainer to review, and commit only on approval with:
```bash
git commit -m "feat(rwl-install-wizard): registry-auth axis — extract pull-secret keys, add Workload Identity path"
```

## Task 1.2: Add the Workload-Identity (secret-free) expected fixture + assertion

**Files:**
- Create: `rwl-install-wizard/tests/fixtures/expected/wi-persource/values-registry.yaml`
- Modify: `rwl-install-wizard/tests/test-airgap-registry.sh` (new WI-fixture assertion block)

**Interfaces:**
- Consumes: the `mirrored-per-upstream` emit (minus pull-secret keys) — i.e. what a `per-source + workload-identity` GENERATE yields.
- Produces: a golden secret-free registry overlay the guard asserts against.

- [ ] **Step 1: Write the failing test** — append to `tests/test-airgap-registry.sh` after the Task-1.1 AUTH block:

```bash
echo "== AUTH: workload-identity fixture is secret-free but fully mirrored =="
WIREG="$SCRIPT_DIR/fixtures/expected/wi-persource/values-registry.yaml"
if [ -f "$WIREG" ]; then
  no_public "$WIREG" "wi-persource values-registry.yaml"
  if grep -qE 'pullSecrets|imagePullSecrets|dockerconfigjsonSecret' "$WIREG"; then
    no "wi-persource overlay contains pull-secret keys (must be secret-free)"; else ok "wi-persource overlay is secret-free"; fi
  if grep -q 'disableLookups: true' "$WIREG"; then ok "wi-persource keeps neo4j disableLookups (MISSED-10)"; else no "wi-persource dropped neo4j disableLookups"; fi
else no "wi-persource fixture missing"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "workload-identity fixture|FAIL:"`
Expected: FAIL `wi-persource fixture missing`.

- [ ] **Step 3: Create the fixture** by copying the airgap per-source registry overlay and removing every pull-secret key. Run:

```bash
mkdir -p "$PLUGIN/tests/fixtures/expected/wi-persource"
# Start from the existing per-source+pull-secret golden, then strip the 5 secret keys.
ruby -e '
  src = File.read("'"$PLUGIN"'/tests/fixtures/expected/airgap/values-registry.yaml")
  out = []
  skip_until_indent = nil
  src.each_line do |ln|
    ind = ln[/^\s*/].length
    if skip_until_indent
      # skip the list item line(s) under a removed key
      if ln.strip.start_with?("-") && ind > skip_until_indent then next end
      skip_until_indent = nil
    end
    key = ln.strip
    if key =~ /^(pullSecrets|imagePullSecrets):\s*$/ then skip_until_indent = ind; next end
    if key =~ /^dockerconfigjsonSecret:\s*/ then next end
    if key =~ /^auth:\s*$/ then
      # drop the ccCatalog.auth wrapper only if its sole child is dockerconfigjsonSecret;
      # here it is — skip this line and its single child handled above.
      skip_until_indent = ind; next
    end
    out << ln
  end
  File.write("'"$PLUGIN"'/tests/fixtures/expected/wi-persource/values-registry.yaml", out.join)
'
```
Then MANUALLY open `tests/fixtures/expected/wi-persource/values-registry.yaml` and verify: no `pullSecrets`, `imagePullSecrets`, `auth:`/`dockerconfigjsonSecret` remain; `disableLookups: true` remains under `neo4j`; `images.registry`, `ccCatalog.config`, all subchart registries remain. Fix any dangling empty parent key by hand.

- [ ] **Step 4: Render-verify the fixture against 0.2.61** (proves WI overlay still mirrors every image and renders):

```bash
helm template rw "$CHART" \
  -f "$PLUGIN/tests/fixtures/expected/wi-persource/values-registry.yaml" \
  -f "$PLUGIN/tests/fixtures/expected/airgap/values-storage.yaml" \
  --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
  --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities --set llmGateway.deploy=false \
  2>/dev/null | grep -oE 'image: \S+' | sort -u | grep -vE 'artifactory\.corp\.example' || echo "ALL-ON-MIRROR"
```
Expected: `ALL-ON-MIRROR` (no image line outside the fixture's `artifactory.corp.example` prefix). If a line leaks, the fixture dropped a needed registry key — fix and re-run.

- [ ] **Step 5: Run the WI assertion**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "workload-identity fixture|secret-free|disableLookups|FAIL:"`
Expected: all PASS; only known-red neo4j may FAIL.

- [ ] **Step 6: Full green-bar** (Setup block). Expected: green except known-red neo4j.

- [ ] **Step 7: Review checkpoint (do NOT commit yet).** Stage, show diff stat, ASK maintainer, then on approval:
```bash
git commit -m "test(rwl-install-wizard): workload-identity secret-free registry fixture + guard"
```

## Task 1.3: Update SKILL.md for the auth axis interview step

**Files:**
- Modify: `rwl-install-wizard/skills/rwl-install/SKILL.md` (Interview section)

**Interfaces:**
- Consumes: the `registry-auth` axis + its `dependsOn` (skip under `connected`).
- Produces: interviewer guidance (no runtime code).

- [ ] **Step 1: Add auth-axis guidance.** In `SKILL.md`, find the `**dependsOn.**` bullet in the Interview section and add a new bullet immediately after it:

```markdown
   - **Registry auth (Boundary 1).** The `registry-auth` axis applies ONLY when a
     mirror layout (`flat-mirror` or `mirrored-per-upstream`) was chosen — skip it
     under `connected` and note the auto-skip. `workload-identity` collects no
     param and emits nothing (secret-free); `pull-secret` requires `pullSecretName`
     (hard re-prompt — required). Default to `pull-secret` for non-GKE registries;
     offer `workload-identity` when the target is GKE + GAR.
```

- [ ] **Step 2: Verify SKILL.md is coherent** (no broken references):

Run: `grep -n "registry-auth\|workload-identity\|pull-secret" "$PLUGIN/skills/rwl-install/SKILL.md"`
Expected: the new bullet appears; wording matches the axis id/options.

- [ ] **Step 3: Full green-bar** (SKILL.md is not lint-checked, but run to confirm nothing regressed).

- [ ] **Step 4: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "docs(rwl-install-wizard): SKILL interview step for registry-auth axis"
```

---

# PHASE 2 — `registry-population` axis + verbose `registry-prerequisites`

## Task 2.1: Add the `registry-population` axis (cache vs explicit) + framing fragments

**Files:**
- Modify: `rwl-install-wizard/data/knob-catalog.yaml` (insert `registry-population` axis after `registry-auth`)
- Create: `rwl-install-wizard/data/guide-sections/registry-population-cache.md`
- Create: `rwl-install-wizard/data/guide-sections/registry-population-explicit.md`

**Interfaces:**
- Produces: axis `registry-population` (no emit; guide sections only), options `cache` / `explicit-mirror`.
- Consumes: the layout-owned manifest (`airgap-image-manifest` per-source; `airgap-image-manifest-flat` flat, added in Phase 3) — referenced by prose, not by id here.

- [ ] **Step 1: Write the failing test** — append to `tests/test-airgap-registry.sh`:

```bash
echo "== POPULATION: registry-population axis exists, guide-only =="
if grep -q 'id: registry-population' "$CATALOG"; then ok "registry-population axis present"; else no "registry-population axis missing"; fi
pop_cache="$(option_block cache)"; pop_expl="$(option_block explicit-mirror)"
for pair in "cache:$pop_cache" "explicit-mirror:$pop_expl"; do
  nm="${pair%%:*}"; blk="${pair#*:}"
  if printf '%s' "$blk" | grep -qE '^\s*emits:'; then no "registry-population=$nm must not emit values"; else ok "registry-population=$nm is guide-only"; fi
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "POPULATION|FAIL:"`
Expected: FAIL `registry-population axis missing`.

- [ ] **Step 3: Insert the axis** after `registry-auth` (before `storage-persistence`):

```yaml
  - id: registry-population
    title: Registry population (Boundary 2)
    # dependsOn: applies only when a mirror layout is chosen. Guide-only — no emit.
    # The image MANIFEST lives on the layout option (airgap-image-manifest for
    # per-source, airgap-image-manifest-flat for flat); this axis only frames what
    # the operator must DO with it.
    question: "How is your registry populated with the images? Pull-through cache (remote/proxy repos load images lazily on first pull — the registry needs egress to the upstreams), or explicit mirror (every image is pushed ahead of time to local/standard repos — true air-gap)?"
    options:
      - id: cache
        label: "Pull-through cache — remote/proxy repos; registry has upstream egress; nothing to push"
        overlay: values-registry.yaml
        emits: {}
        guide_sections: [registry-population-cache]
        known_issues: []
      - id: explicit-mirror
        label: "Explicit mirror — local/standard repos; every image pushed ahead of time (air-gap)"
        overlay: values-registry.yaml
        emits: {}
        guide_sections: [registry-population-explicit]
        known_issues: []
```

- [ ] **Step 4: Create `data/guide-sections/registry-population-cache.md`:**

```markdown
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
```

- [ ] **Step 5: Create `data/guide-sections/registry-population-explicit.md`:**

```markdown
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
```

- [ ] **Step 6: Run the population assertion + lint**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "POPULATION|FAIL:"` then the lint from Setup.
Expected: POPULATION lines PASS; LINT-OK.

- [ ] **Step 7: Full green-bar.** Expected green except known-red neo4j.

- [ ] **Step 8: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "feat(rwl-install-wizard): registry-population axis (cache vs explicit runbook framing)"
```

## Task 2.2: Verbose tokenized `registry-prerequisites` fragment, wired to both mirror layouts

**Files:**
- Create: `rwl-install-wizard/data/guide-sections/registry-prerequisites.md`
- Modify: `rwl-install-wizard/data/knob-catalog.yaml` (add `registry-prerequisites` to `mirrored-per-upstream.guide_sections`; `flat-mirror` gets it in Phase 3)

**Interfaces:**
- Consumes: tokens `<REGISTRY_HOST>`, `<PULL_SECRET_NAME>` (present in pull-secret mode). Uses canonical remote names (convention, stated verbatim).
- Produces: the operator-facing prerequisite checklist.

- [ ] **Step 1: Write the failing test** — append to `tests/test-airgap-registry.sh`:

```bash
echo "== PREREQS: registry-prerequisites fragment wired + names the private source-GAR repo =="
PRQ="$PLUGIN_DIR/data/guide-sections/registry-prerequisites.md"
if [ -f "$PRQ" ]; then
  grep -q 'docker-runwhen-self-hosted' "$PRQ" && grep -qiE 'RunWhen.*(key|credential)' "$PRQ" && ok "registry-prerequisites names the private RunWhen source-GAR repo + key" || no "registry-prerequisites missing private source-GAR/key callout"
  grep -q '<REGISTRY_HOST>' "$PRQ" && ok "registry-prerequisites is tokenized on REGISTRY_HOST" || no "registry-prerequisites not tokenized"
else no "registry-prerequisites fragment missing"; fi
grep -q 'registry-prerequisites' "$CATALOG" && ok "registry-prerequisites referenced by catalog" || no "registry-prerequisites not referenced"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "PREREQS|FAIL:"`
Expected: FAIL `registry-prerequisites fragment missing`.

- [ ] **Step 3: Create `data/guide-sections/registry-prerequisites.md`:**

```markdown
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

- **Registry/platform admin** creates these repos and (Boundary 2) attaches the
  upstream creds above. The `docker-runwhen-self-hosted` repo will not resolve any
  RunWhen first-party image until the RunWhen source-GAR key is attached.
- **Cluster admin** sets up Boundary-1 pull auth (see the registry pull-auth
  section — either Workload Identity or the `<PULL_SECRET_NAME>` Secret).

**Pre-flight check:** after the repos exist and Boundary-1 auth is set, run the
image render-gate in the install section; every image line must start with
`<REGISTRY_HOST>`.
```

- [ ] **Step 4: Wire it into `mirrored-per-upstream.guide_sections`** in `data/knob-catalog.yaml`. Change that option's line:

`guide_sections: [registry-jfrog-per-upstream, subchart-alias-mirroring, airgap-image-manifest, chart-version, secret-preflight-checklist, helm-install-command]`

to include `registry-prerequisites` first:

`guide_sections: [registry-prerequisites, registry-jfrog-per-upstream, subchart-alias-mirroring, airgap-image-manifest, chart-version, secret-preflight-checklist, helm-install-command]`

- [ ] **Step 5: Render-verify the generated PREREQ substitutes real values** (use the stoxx profile, which is per-source + pull-secret):

```bash
cd /Users/rohitekbote/wd/fde/stoxx 2>/dev/null && \
ruby "$PLUGIN/lib/build-guide.rb" --catalog "$PLUGIN/data/knob-catalog.yaml" \
  --profile .claude/rwl-install-profile.yaml --data "$PLUGIN/data" --out rwl-install-out >/dev/null && \
grep -c 'europe-docker.pkg.dev/stoxx-rw-poc' rwl-install-out/USER-GUIDE.html
```
Expected: a positive count AND (open USER-GUIDE.html) the Registry-prerequisites table shows the operator's `<REGISTRY_HOST>` substituted, `docker-runwhen-self-hosted` present, and no literal `<REGISTRY_HOST>` leak. (If the stoxx profile is absent, skip this step and rely on Step 6.)

- [ ] **Step 6: Run the prereq assertion + lint**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "PREREQS|FAIL:"` and the Setup lint.
Expected: PREREQS PASS; LINT-OK (fragment is referenced, so no orphan).

- [ ] **Step 7: Full green-bar.** Expected green except known-red neo4j.

- [ ] **Step 8: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "feat(rwl-install-wizard): verbose tokenized registry-prerequisites section"
```

## Task 2.3: Update SKILL.md for the population step

**Files:**
- Modify: `rwl-install-wizard/skills/rwl-install/SKILL.md`

- [ ] **Step 1: Add population guidance** after the registry-auth bullet added in Task 1.3:

```markdown
   - **Registry population (Boundary 2).** The `registry-population` axis also
     applies only when a mirror layout was chosen — skip under `connected`. It emits
     no values; it selects the runbook framing (`cache` = admin maps remote repos
     once, nothing to push; `explicit-mirror` = every image pushed ahead of time).
     It does NOT change overlay keys.
```

- [ ] **Step 2: Verify** — `grep -n "registry-population" "$PLUGIN/skills/rwl-install/SKILL.md"` shows the bullet.

- [ ] **Step 3: Full green-bar.** Expected unchanged (green except known-red neo4j).

- [ ] **Step 4: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then commit on approval:
```bash
git commit -m "docs(rwl-install-wizard): SKILL interview step for registry-population axis"
```

---

# PHASE 3 — `flat-mirror` layout option + flat manifest

## Task 3.1: Create the flat image manifest fragment (from the verified 0.2.61 render)

**Files:**
- Create: `rwl-install-wizard/data/guide-sections/airgap-image-manifest-flat.md`

**Interfaces:**
- Consumes: token `<FLAT_PREFIX>` (from the flat-mirror `flatPrefix` param, Task 3.2).
- Produces: the flat push-target list (first-party flattened; subcharts path-preserved under the flat prefix).

- [ ] **Step 1: Regenerate the ground-truth flat image set** to author the manifest accurately:

```bash
helm template rw "$CHART" \
  --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
  --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities --set llmGateway.deploy=false \
  --set-string registryOverride="FLATPREFIX" \
  --set-string neo4j.image.customImage=FLATPREFIX/library/neo4j:5.26.28 \
  --set-string vault.server.image.repository=FLATPREFIX/hashicorp/vault --set-string vault.server.image.tag=2.0.3 \
  --set-string redis.image.registry=FLATPREFIX --set-string redis.image.repository=bitnamilegacy/redis \
  --set-string qdrant.image.repository=FLATPREFIX/qdrant/qdrant \
  --set-string metricstore.image.registry=FLATPREFIX \
  2>/dev/null | grep -oE 'image: \S+' | sed 's/image: //;s/"//g' | sort -u
```
Read the output — every line should start with `FLATPREFIX` except any you must still add a subchart key for (seaweedfs/bci). Note the exact repo paths for the manifest.

- [ ] **Step 2: Create `data/guide-sections/airgap-image-manifest-flat.md`** using the verified paths. Body:

```markdown
### Air-gap image manifest — FLAT layout (`<FLAT_PREFIX>`)

You chose a FLAT / virtual-repo layout, so `registryOverride: <FLAT_PREFIX>`
**flattens** first-party and wrapper images (the source path is dropped), while
the pure subcharts keep their repository path under the prefix. Mirror exactly
these targets (preserving each path shown):

```text
# First-party + ghcr first-party + utility + wrapper subcharts (flattened by registryOverride):
<FLAT_PREFIX>/backend-services:<tag>
<FLAT_PREFIX>/agent-farm:<tag>
<FLAT_PREFIX>/runner-control:<tag>
<FLAT_PREFIX>/webhooks-service:<tag>
<FLAT_PREFIX>/usearch:<tag>
<FLAT_PREFIX>/ui:<tag>
<FLAT_PREFIX>/shared-services:<tag>
<FLAT_PREFIX>/cc-catalog-svc:<tag>
<FLAT_PREFIX>/cortex-tenant:<tag>
<FLAT_PREFIX>/runwhen-platform-mcp:<tag>
<FLAT_PREFIX>/litellm-non_root:<tag>            # if llmGateway deployed
<FLAT_PREFIX>/library/busybox:1.36
<FLAT_PREFIX>/hashicorp/vault:1.21.2            # utility/init/unseal/backup (aux)
<FLAT_PREFIX>/spilo-17:4.0-p2
<FLAT_PREFIX>/grafana/mimir:2.14.0
<FLAT_PREFIX>/edoburu/pgbouncer:v1.24.1-p1      # if pgbouncer enabled
<FLAT_PREFIX>/bitnamilegacy/postgresql:...      # if bundled postgres (kind=bundled)

# Pure subcharts (registryOverride does NOT reach these — set via explicit keys, path-preserved):
<FLAT_PREFIX>/bitnamilegacy/redis:8.2.1-debian-12-r0
<FLAT_PREFIX>/library/neo4j:5.26.28
<FLAT_PREFIX>/hashicorp/vault:2.0.3             # subchart server
<FLAT_PREFIX>/qdrant/qdrant:v1.18.0
<FLAT_PREFIX>/chrislusf/seaweedfs:4.25
<FLAT_PREFIX>/bci/bci-base:15.7                 # helm-test only
```

> Tags track your resolved chart/subchart versions — confirm against `Chart.lock`
> and the chart-version section. The three hard-pinned subchart tags
> (`neo4j 5.26.28`, `vault 2.0.3`, `bci-base 15.7`) plus the aux `vault 1.21.2` are
> the same as the per-source manifest.

**Validation (run before install):**
```bash
helm template <RELEASE> <CHART_REF> -f values-registry.yaml <other -f overlays> \
  | grep -oE 'image: \S+' | sort -u
```
Every line must start with `<FLAT_PREFIX>`. Any residual `docker.io` / `ghcr.io` /
`us-docker.pkg.dev` / `registry.suse.com` is an image the overlay has not
re-pointed — fix the overlay (or push+map that image), then re-render.
```

- [ ] **Step 3: Lint** (fragment is orphan until Task 3.2 references it — so DEFER lint to Task 3.2). For now just confirm the file exists:

Run: `test -f "$PLUGIN/data/guide-sections/airgap-image-manifest-flat.md" && echo OK`
Expected: `OK`.

- [ ] **Step 4: No commit yet** — this fragment must be referenced (Task 3.2) or `catalog-lint` orphan-check fails. Proceed directly to Task 3.2; commit them together at Task 3.2's checkpoint.

## Task 3.2: Add the `flat-mirror` option to `registry-routing`

**Files:**
- Modify: `rwl-install-wizard/data/knob-catalog.yaml` (new option in `registry-routing`)

**Interfaces:**
- Consumes: `<FLAT_PREFIX>` (new param), the pinned-tags notice (same values as per-source).
- Produces: a flat overlay = `registryOverride` + Part-2 subchart keys.

- [ ] **Step 1: Write the failing test** — append to `tests/test-airgap-registry.sh`:

```bash
echo "== FLAT: flat-mirror option renders every image on the flat prefix =="
if grep -q 'id: flat-mirror' "$CATALOG"; then ok "flat-mirror option present"; else no "flat-mirror option missing"; fi
flat="$(option_block flat-mirror)"
printf '%s' "$flat" | grep -qE 'registryOverride:\s*"<FLAT_PREFIX>"' && ok "flat-mirror sets registryOverride token" || no "flat-mirror missing registryOverride"
for sub in "redis" "neo4j" "vault" "qdrant" "seaweedfs" "metricstore"; do
  printf '%s' "$flat" | grep -q "$sub" && ok "flat-mirror emits $sub subchart key" || no "flat-mirror missing $sub subchart key"
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "FLAT:|flat-mirror|FAIL:"`
Expected: FAIL `flat-mirror option missing`.

- [ ] **Step 3: Insert the `flat-mirror` option** into `registry-routing`, between `connected` and `mirrored-per-upstream`:

```yaml
      - id: flat-mirror
        label: "Flat mirror — ONE prefix / virtual repository fronts every image (GAR/JFrog virtual repo). Uses registryOverride."
        overlay: values-registry.yaml
        params:
          - { id: flatPrefix, prompt: "The single flat prefix (host + path) that fronts every image, e.g. us-central1-docker.pkg.dev/acme/rw-virtual or a JFrog virtual repo. If you actually have a separate repo per upstream source, choose the per-upstream option instead.", required: true }
        emits:
          x-airgap-pinned-tags-notice:
            warning: >-
              PINNED subchart image tags in this overlay target chart ~0.2.x. VERIFY
              each against your Chart.lock and the FLAT air-gap image manifest in your
              USER-GUIDE before installing — the registry must hold the exact tag your
              chart resolves, or the image pull fails.
            pinnedTags:
              neo4j: "5.26.28"
              vault: "2.0.3"
              bciBaseHelmTest: "15.7"
          # FLAT layout: registryOverride reaches first-party + utility + wrapper
          # subcharts (flattened). The pure subcharts below still need explicit keys.
          registryOverride: "<FLAT_PREFIX>"
          neo4j:
            disableLookups: true
            image:
              customImage: "<FLAT_PREFIX>/library/neo4j:5.26.28"   # PINNED-TAG 5.26.28
          vault:
            server:
              image:
                repository: "<FLAT_PREFIX>/hashicorp/vault"
                tag: "2.0.3"            # PINNED-TAG 2.0.3 (subchart server); aux stays 1.21.2 (inherited)
          redis:
            image:
              registry: "<FLAT_PREFIX>"
              repository: "bitnamilegacy/redis"
          qdrant:
            disableLookups: true
            image:
              repository: "<FLAT_PREFIX>/qdrant/qdrant"
            chartTests:
              dbInteraction:
                image: "<FLAT_PREFIX>/bci/bci-base:15.7"   # PINNED-TAG 15.7
          metricstore:
            image:
              registry: "<FLAT_PREFIX>"
          seaweedfs:
            global:
              seaweedfs:
                image:
                  name: "<FLAT_PREFIX>/chrislusf/seaweedfs"
            image:
              repository: "<FLAT_PREFIX>/chrislusf/seaweedfs"
        guide_sections: [registry-prerequisites, airgap-image-manifest-flat, chart-version, helm-install-command]
        known_issues: [hardcoded-image-refs, embedder-airgap-hang, thin-chart-subchart-aliases, seaweedfs-image-chrislusf]
```

- [ ] **Step 4: Render-gate — flat overlay lands EVERY image on the flat prefix.** Build a temp flat overlay by substituting the token, then render:

```bash
TMP="$PLUGIN/../.rwl-flat-probe"; mkdir -p "$TMP"
# Extract the flat-mirror emit, substitute <FLAT_PREFIX> -> a test prefix, write an overlay.
ruby -ryaml -e '
  cat = YAML.load_file("'"$PLUGIN"'/data/knob-catalog.yaml")
  ax = cat["axes"].find{|a| a["id"]=="registry-routing"}
  opt = ax["options"].find{|o| o["id"]=="flat-mirror"}
  emit = opt["emits"].reject{|k,_| k=="x-airgap-pinned-tags-notice"}
  txt = YAML.dump(emit).gsub("<FLAT_PREFIX>","flatreg.example/rw-virtual")
  File.write("'"$TMP"'/values-registry.yaml", txt)
'
helm template rw "$CHART" -f "$TMP/values-registry.yaml" \
  --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
  --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities --set llmGateway.deploy=false \
  2>/dev/null | grep -oE 'image: \S+' | sed 's/image: //;s/"//g' | sort -u \
  | grep -vE '^flatreg\.example/rw-virtual' || echo "ALL-ON-FLAT-PREFIX"
```
Expected: `ALL-ON-FLAT-PREFIX`. If any line leaks (e.g. a subchart not covered), add its key to the `flat-mirror` emit and re-run. Then `rm -rf "$TMP"`.

- [ ] **Step 5: Lint** (now that both the fragment and option exist):

Run: `bash "$PLUGIN/lib/catalog-lint.sh" "$PLUGIN/data/knob-catalog.yaml" "$PLUGIN/data" && echo LINT-OK`
Expected: `LINT-OK` (airgap-image-manifest-flat now referenced — no orphan).

- [ ] **Step 6: FLAT assertion**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "FLAT:|FAIL:"`
Expected: FLAT PASS. NOTE: the MISSED-1 guard will now FAIL (`flat-mirror still present`, `catalog still emits registryOverride`) — that is EXPECTED and fixed in Task 3.3. Do not commit yet.

- [ ] **Step 7: No commit** — proceed to Task 3.3 (the MISSED-1 guard must be rewritten before green-bar). Commit Tasks 3.1+3.2+3.3 together at 3.3's checkpoint.

## Task 3.3: Rewrite the MISSED-1 guard; add the flat expected fixture

**Files:**
- Modify: `rwl-install-wizard/tests/test-airgap-registry.sh` (the `== MISSED-1 ==` block)
- Create: `rwl-install-wizard/tests/fixtures/expected/flat/values-registry.yaml`

**Interfaces:**
- Consumes: the `flat-mirror` emit (Task 3.2).
- Produces: a corrected guard that permits FLAT *with its own manifest* while still forbidding `registryOverride` in the PER-SOURCE overlay.

- [ ] **Step 1: Rewrite the MISSED-1 guard block.** In `tests/test-airgap-registry.sh`, replace the four `MISSED-1: registryOverride removed` assertions (the `flat-mirror still present`, `catalog never emits registryOverride`, `values-registry.yaml sets registryOverride` checks) with layout-aware ones:

```bash
echo "== MISSED-1 (revised): per-source overlays never use registryOverride; flat does, with its own manifest =="
# Per-source is still path-preserving and must NEVER set registryOverride.
persrc="$(option_block mirrored-per-upstream)"
if printf '%s' "$persrc" | grep -qE 'registryOverride[[:space:]]*:'; then no "mirrored-per-upstream must not set registryOverride"; else ok "mirrored-per-upstream never sets registryOverride"; fi
if nocomment "$REG" | grep -qE 'registryOverride[[:space:]]*:'; then no "per-source fixture values-registry.yaml sets registryOverride"; else ok "per-source fixture has no registryOverride"; fi
# Flat is now a supported layout and MUST pair registryOverride with its flat manifest.
flat="$(option_block flat-mirror)"
if printf '%s' "$flat" | grep -qE 'registryOverride[[:space:]]*:'; then ok "flat-mirror uses registryOverride (expected for flat layout)"; else no "flat-mirror missing registryOverride"; fi
if printf '%s' "$flat" | grep -q 'airgap-image-manifest-flat'; then ok "flat-mirror references the flat image manifest"; else no "flat-mirror must reference airgap-image-manifest-flat (MISSED-1 guard: no flat overlay without a flat manifest)"; fi
```

- [ ] **Step 2: Create the flat expected fixture** by rendering the emit with a concrete prefix:

```bash
mkdir -p "$PLUGIN/tests/fixtures/expected/flat"
ruby -ryaml -e '
  cat = YAML.load_file("'"$PLUGIN"'/data/knob-catalog.yaml")
  opt = cat["axes"].find{|a| a["id"]=="registry-routing"}["options"].find{|o| o["id"]=="flat-mirror"}
  hdr = "# values-registry.yaml (flat) — generated by rwl-install wizard. DO NOT hand-edit.\n"
  txt = hdr + YAML.dump(opt["emits"]).gsub("<FLAT_PREFIX>","flatreg.example/rw-virtual").sub(/^---\n/,"")
  File.write("'"$PLUGIN"'/tests/fixtures/expected/flat/values-registry.yaml", txt)
'
grep -c 'flatreg.example/rw-virtual' "$PLUGIN/tests/fixtures/expected/flat/values-registry.yaml"
```
Expected: a positive count. Open the file and confirm `registryOverride: flatreg.example/rw-virtual` plus the subchart keys are present.

- [ ] **Step 3: Add a flat-fixture assertion** to `tests/test-airgap-registry.sh` (after the revised MISSED-1 block):

```bash
echo "== FLAT: fixture is fully on the flat prefix, no public host =="
FLATREG="$SCRIPT_DIR/fixtures/expected/flat/values-registry.yaml"
if [ -f "$FLATREG" ]; then
  if grep -nE "$PUBLIC_HOSTS" "$FLATREG" | grep -vE 'git_url|repoUrl|github\.com' >/dev/null; then no "flat fixture leaks a public host"; else ok "flat fixture has no public host"; fi
  grep -q 'registryOverride: flatreg.example/rw-virtual' "$FLATREG" && ok "flat fixture sets registryOverride" || no "flat fixture missing registryOverride"
else no "flat fixture missing"; fi
```

- [ ] **Step 4: Run the full airgap-registry test**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-airgap-registry.sh" 2>&1 | grep -E "passed, [0-9]+ failed|FAIL:"`
Expected: `N passed, 1 failed` where the ONLY failure is the known-red neo4j line. All MISSED-1 (revised) and FLAT lines PASS.

- [ ] **Step 5: Full green-bar** (Setup block). Expected: LINT-OK; suites green except known-red neo4j.

- [ ] **Step 6: Review checkpoint (do NOT commit yet).** This commit covers Tasks 3.1+3.2+3.3. Stage, show diff, ASK maintainer, then on approval:
```bash
git add -A && git commit -m "feat(rwl-install-wizard): flat-mirror layout option + flat image manifest; revise MISSED-1 guard"
```

## Task 3.4: SKILL.md layout-question update + close-out

**Files:**
- Modify: `rwl-install-wizard/skills/rwl-install/SKILL.md`

- [ ] **Step 1: Add layout guidance** to the Interview section (near the registry bullets from Phase 1/2):

```markdown
   - **Registry layout (mechanism).** `registry-routing` now picks LAYOUT: ask
     concretely "do ALL images sit under one prefix / a virtual repository, or a
     separate repo per upstream source?" One prefix / virtual repo → `flat-mirror`
     (collect `flatPrefix`; emits `registryOverride` + subchart keys). Per-source →
     `mirrored-per-upstream`. Never infer the mechanism from the registry vendor —
     only from this layout answer. If the operator is unsure, route them to their
     registry admin rather than guessing.
```

- [ ] **Step 2: Update the apply-order note if present.** Search `SKILL.md` for the overlay apply-order line and confirm `values-registry` still appears first among generated overlays (unchanged). No edit needed unless the text enumerates registry options by name.

Run: `grep -n "values-registry\|registryOverride\|flat-mirror\|per-source" "$PLUGIN/skills/rwl-install/SKILL.md"`
Expected: the new layout bullet present; no stale claim that flat/registryOverride is forbidden.

- [ ] **Step 3: Final full green-bar** (Setup block). Expected: LINT-OK; green except known-red neo4j.

- [ ] **Step 4: Regenerate the stoxx kit as a smoke test** (if the profile exists) to confirm end-to-end assembly still works:
```bash
cd /Users/rohitekbote/wd/fde/stoxx 2>/dev/null && ruby "$PLUGIN/lib/build-guide.rb" \
  --catalog "$PLUGIN/data/knob-catalog.yaml" --profile .claude/rwl-install-profile.yaml \
  --data "$PLUGIN/data" --out rwl-install-out && echo "BUILD OK"
```
Expected: `BUILD OK` (or skipped if no profile).

- [ ] **Step 5: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "docs(rwl-install-wizard): SKILL layout question for flat vs per-source registry"
```

- [ ] **Step 6: Version bump + hand-off.** Bump `rwl-install-wizard/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (plugin entry) `0.3.1` → `0.4.0` (new feature set). Stage, show diff, ASK maintainer, then commit:
```bash
git commit -m "chore(rwl-install-wizard): 0.4.0 — registry layout/auth/population axes + verbose prereqs"
```
Then report: branch, all commits, and remind the maintainer to open/refresh the PR.

---

## Notes carried from the spec (do not re-derive)

- `registryOverride` on 0.2.61 reaches + flattens first-party, ghcr first-party, `images.llmGateway`, utility, and wrapper subcharts (spilo/mimir/pgbouncer/bundled-postgres); it does NOT reach redis/neo4j/vault-server/qdrant/seaweedfs/bci — those always need explicit keys.
- `neo4j.disableLookups: true` stays in the LAYOUT emit (both flat and per-source), NOT the auth axis — it is required whenever `imagePullSecrets` is set and harmless otherwise.
- Pinned tags are unchanged across layouts: neo4j `5.26.28`, vault server `2.0.3`, bci `15.7`, aux vault `1.21.2`.
- The one permitted red test everywhere is `byo: KNOWN neo4jUri consumer red (chart bug neo4j-external-agentfarm-usearch)`.

## Known follow-up (out of this plan's gate)

The `/rwl-catalog-update` drift detector (`detect-drift.sh`) renders each option in
ISOLATION. After this change, rendering `registry-auth=pull-secret` alone emits
`neo4j.image.imagePullSecrets` WITHOUT the layout's `neo4j.disableLookups: true`
(which now lives on the layout options) — that trips the MISSED-10 fail-fast and
would surface as a spurious `render` drift finding. This plan's gate is
`catalog-lint` + `run-all.sh` (not the detector), so it does not block here, but a
follow-up should teach the detector to render auth/population options MERGED with a
representative layout option rather than in isolation. Do NOT "fix" it by
duplicating `disableLookups` into the auth emit — that re-couples the auth axis to a
neo4j concern the layout axis owns.
