# Email-Config Axis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-level `email-config` axis to the rwl-install-wizard so operators either configure an SMTP relay or disable email (skip verification).

**Architecture:** One single-select axis mirroring `llm-endpoint`, overlaying into `values-cluster.yaml`, with two options — `email-smtp` (configure SMTP; secret-free BYO creds Secret) and `email-disabled` (`papi.skipEmailVerification: "true"`). Plus two guide fragments, one known-issue, an SMTP item in the secret checklist, profile fixtures, a helm-render regression test, and the SKILL interview step.

**Tech Stack:** YAML catalog (`data/knob-catalog.yaml`), Markdown guide fragments, Ruby assembler (`lib/build-guide.rb`, unchanged), bash tests, Helm 3 render-gate.

## Global Constraints

- **Chart:** render-verify against **0.2.63** at `$CHART` = `/Users/rohitekbote/wd/code/github.com/runwhen/rwlight-helm/charts/runwhen-platform` (subcharts already vendored; `helm` installed).
- **Overlay target:** all `email-config` emits go to `values-cluster.yaml`.
- **Secret-free:** never emit or template a secret VALUE; the SMTP creds are wired by name via `email.smtp.existingSecret`. Guide secret templates use `<placeholder>` values only.
- **Leak-safety:** `build-guide.rb`'s `substitution_map` drops blank params, so any `<TOKEN>` in an emit for an UNSET param renders literally. Required params (`smtpHost`, `smtpExistingSecret`) always answer; the default-valued params (`smtpPort`=`587`, `smtpTlsMode`=`starttls`, `emailFromAddress`=`noreply@runwhen.com`) MUST be stored in the profile (never blank) so their tokens always resolve.
- **Token map (verify against `screaming` = camelCase→UPPER_SNAKE):** `smtpHost`→`<SMTP_HOST>`, `smtpExistingSecret`→`<SMTP_EXISTING_SECRET>`, `smtpPort`→`<SMTP_PORT>`, `smtpTlsMode`→`<SMTP_TLS_MODE>`, `emailFromAddress`→`<EMAIL_FROM_ADDRESS>`.
- **Chart fact:** empty `EMAIL_PROVIDER` crashes PAPI startup — the `email-smtp` emit pins `provider: "smtp"`.
- **catalog-lint:** every `guide_sections`/`known_issues` id has a backing `.md`; no orphans.
- **Never commit without asking.** Each task ends with a review checkpoint: stage, show `git status` + `git diff --stat`, and ASK the maintainer before committing. Do NOT edit `skills/` except the explicit SKILL task.

## Setup (run once)

```bash
cd /Users/rohitekbote/emdash/worktrees/rw-plugins/emdash/main-for-qna-lcngl
export PLUGIN=$PWD/rwl-install-wizard
export CHART=/Users/rohitekbote/wd/code/github.com/runwhen/rwlight-helm/charts/runwhen-platform
test -f "$CHART/Chart.yaml" && echo "CHART OK ($(grep -m1 '^version:' $CHART/Chart.yaml))" || echo "CHART MISSING"
```

**Green-bar (every task's final verification):**
```bash
bash "$PLUGIN/lib/catalog-lint.sh" "$PLUGIN/data/knob-catalog.yaml" "$PLUGIN/data" && echo LINT-OK
RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/run-all.sh" 2>&1 | grep -E "passed, [0-9]+ failed|FAIL:"
```
Expected: `LINT-OK`; every suite `N passed, 0 failed` EXCEPT `airgap-registry`, whose ONLY allowed failure is exactly `byo: KNOWN neo4jUri consumer red (chart bug neo4j-external-agentfarm-usearch)`.

---

## Task 1: `email-config` axis + options + fragments + render test

**Files:**
- Modify: `rwl-install-wizard/data/knob-catalog.yaml` (insert axis after `llm-endpoint` ends at line 959, before `- id: subcharts` at line 960)
- Create: `rwl-install-wizard/data/guide-sections/email-smtp.md`
- Create: `rwl-install-wizard/data/guide-sections/email-disabled.md`
- Create: `rwl-install-wizard/data/known-issues/email-empty-provider-crash.md`
- Create: `rwl-install-wizard/tests/test-email-config.sh`

**Interfaces:**
- Produces: axis `email-config` with options `email-smtp` (params `smtpHost`, `smtpExistingSecret`, `smtpPort`, `smtpTlsMode`, `emailFromAddress`) and `email-disabled` (no params). Fragment ids `email-smtp`, `email-disabled`, `email-empty-provider-crash`.

- [ ] **Step 1: Write the failing test** — create `rwl-install-wizard/tests/test-email-config.sh` (run-all globs `test-*.sh`, so it auto-registers):

```bash
#!/usr/bin/env bash
# test-email-config.sh — the email-config axis renders the right PAPI/email env.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CATALOG="$PLUGIN_DIR/data/knob-catalog.yaml"
CHART="${RWL_CHART_PATH:-/Users/rohitekbote/wd/code/github.com/runwhen/rwlight-helm/charts/runwhen-platform}"
PASS=0; FAIL=0
ok(){ printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL+1)); }

# Extract one option's emits, substitute <TOKENS> with test values, write an overlay.
emit_overlay() {  # <option-id> <out-file> [TOKEN=value ...]
  local opt="$1" out="$2"; shift 2
  ruby -ryaml -e '
    cat=YAML.load_file(ARGV[0]); want=ARGV[1]; out=ARGV[2]
    subs={}; ARGV[3..-1].to_a.each{|kv| k,v=kv.split("=",2); subs[k]=v}
    em=nil
    (cat["axes"]||[]).each{|a| (a["options"]||[]).each{|o| em=o["emits"] if o["id"]==want}}
    abort "no option #{want}" unless em
    s=YAML.dump(em); subs.each{|k,v| s=s.gsub("<#{k}>", v)}
    File.write(out, s)
  ' "$CATALOG" "$opt" "$out" "$@"
}

if ! command -v helm >/dev/null 2>&1 || [ ! -f "$CHART/values.yaml" ]; then
  echo "  SKIP: no helm/chart — email render checks skipped"
  echo ""; echo "email-config: 0 passed, 0 failed"; exit 0
fi

render() { helm template rw "$CHART" \
  --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
  --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities \
  --set llmGateway.deploy=false -f "$1" 2>/dev/null; }

TMP="$(mktemp -d)"

echo "== email-disabled: SKIP_EMAIL_VERIFICATION=true =="
emit_overlay email-disabled "$TMP/d.yaml"
render "$TMP/d.yaml" | grep -q 'SKIP_EMAIL_VERIFICATION: "true"' \
  && ok "email-disabled sets SKIP_EMAIL_VERIFICATION true" || no "email-disabled missing SKIP_EMAIL_VERIFICATION true"

echo "== email-smtp: EMAIL_* env + secret ref, verification enforced =="
emit_overlay email-smtp "$TMP/s.yaml" \
  SMTP_HOST=smtp.corp.example SMTP_PORT=587 SMTP_TLS_MODE=starttls \
  SMTP_EXISTING_SECRET=rw-smtp-creds EMAIL_FROM_ADDRESS=noreply@corp.example
r="$(render "$TMP/s.yaml")"
echo "$r" | grep -q 'EMAIL_PROVIDER: "smtp"'                 && ok "provider=smtp"            || no "provider not smtp"
echo "$r" | grep -q 'EMAIL_SMTP_HOST: "smtp.corp.example"'   && ok "EMAIL_SMTP_HOST set"      || no "EMAIL_SMTP_HOST missing"
echo "$r" | grep -q 'EMAIL_SMTP_PORT: "587"'                 && ok "EMAIL_SMTP_PORT set"      || no "EMAIL_SMTP_PORT missing"
echo "$r" | grep -q 'EMAIL_SMTP_TLS_MODE: "starttls"'        && ok "EMAIL_SMTP_TLS_MODE set"  || no "EMAIL_SMTP_TLS_MODE missing"
echo "$r" | grep -q 'rw-smtp-creds'                          && ok "SMTP secret ref wired"    || no "SMTP secret ref missing"
echo "$r" | grep -q 'SKIP_EMAIL_VERIFICATION: "false"'       && ok "verification enforced"    || no "skip flag not false"

rm -rf "$TMP"
echo ""; echo "email-config: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x "$PLUGIN/tests/test-email-config.sh"; RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-email-config.sh" 2>&1 | tail -5`
Expected: FAIL — `emit_overlay` aborts with `no option email-disabled` (the axis does not exist yet), so the suite reports failures.

- [ ] **Step 3: Insert the `email-config` axis** into `data/knob-catalog.yaml`, immediately AFTER the `llm-endpoint` axis's last line (the `known_issues:` line at 959) and BEFORE `  - id: subcharts` (line 960). Insert exactly:

```yaml
  - id: email-config
    title: Email server
    question: "Should the platform send email (account verification, notifications) via an SMTP relay, or run without email? Without email, verification is disabled so accounts can be used."
    options:
      - id: email-smtp
        label: "SMTP relay — send email through your SMTP server (verification enforced)"
        overlay: values-cluster.yaml
        params:
          - { id: smtpHost, prompt: "SMTP relay hostname (e.g. smtp.corp.example — the mail server the platform sends through).", required: true }
          - { id: smtpExistingSecret, prompt: "Name of a pre-created Kubernetes Secret in the release namespace holding EMAIL_SMTP_USERNAME + EMAIL_SMTP_PASSWORD (existingSecret name — not the credentials).", required: true }
          - { id: smtpPort, prompt: "SMTP port (587 = STARTTLS, 465 = SSL, 25 = none). Default 587." }
          - { id: smtpTlsMode, prompt: "TLS mode: starttls | ssl | none. Default starttls." }
          - { id: emailFromAddress, prompt: "Envelope sender address (e.g. noreply@corp.example). Default noreply@runwhen.com." }
        emits:
          email:
            provider: "smtp"          # empty EMAIL_PROVIDER crashes PAPI (see email-empty-provider-crash)
            fromAddress: "<EMAIL_FROM_ADDRESS>"
            smtp:
              host: "<SMTP_HOST>"
              port: "<SMTP_PORT>"
              tlsMode: "<SMTP_TLS_MODE>"
              existingSecret: "<SMTP_EXISTING_SECRET>"
          papi:
            skipEmailVerification: "false"
        guide_sections: [email-smtp, secret-preflight-checklist]
        known_issues: [email-empty-provider-crash]

      - id: email-disabled
        label: "No email — disable email verification (accounts sign up / log in without a verified address)"
        overlay: values-cluster.yaml
        emits:
          papi:
            skipEmailVerification: "true"
        guide_sections: [email-disabled]
        known_issues: []
```

- [ ] **Step 4: Create `data/guide-sections/email-smtp.md`:**

```markdown
### Email — SMTP relay

You chose to send platform email through an SMTP relay. The kit sets
`email.provider: smtp` plus the relay coordinates, and keeps email verification
**enforced** (`papi.skipEmailVerification: "false"`).

**You must pre-create the credentials Secret `<SMTP_EXISTING_SECRET>`** in the release namespace (the wizard never handles secret material) — standard keys `EMAIL_SMTP_USERNAME` / `EMAIL_SMTP_PASSWORD`:

    kubectl -n <NAMESPACE> create secret generic <SMTP_EXISTING_SECRET> \
      --from-literal=EMAIL_SMTP_USERNAME='<user>' \
      --from-literal=EMAIL_SMTP_PASSWORD='<pass>'

- Relay `<SMTP_HOST>` on port `<SMTP_PORT>`, TLS mode `<SMTP_TLS_MODE>` — the port and TLS mode must match your relay (587=STARTTLS, 465=SSL, 25=none).
- Envelope sender `<EMAIL_FROM_ADDRESS>`.
- The Secret may also carry `EMAIL_PROVIDER=smtp` and override the host/port/tls keys; keys set in the Secret win over the ConfigMap.
```

- [ ] **Step 5: Create `data/guide-sections/email-disabled.md`:**

```markdown
### Email — disabled (verification skipped)

You chose NOT to configure email. The kit sets `papi.skipEmailVerification: "true"` (PAPI `SKIP_EMAIL_VERIFICATION=true`), so accounts can sign up and log in without a verified email address — necessary because the platform defaults to ENFORCING verification, which would otherwise lock users out when no email provider is wired.

> **Security note.** The chart labels this a dev convenience — it weakens account security (anyone can register any email without proving they control it). Use it only where unverified-email login is acceptable. To harden later, configure an SMTP relay (re-run the wizard, choose the SMTP option) and drop the skip.
```

- [ ] **Step 6: Create `data/known-issues/email-empty-provider-crash.md`:**

```markdown
## Empty EMAIL_PROVIDER crashes PAPI at startup

**Symptom:** PAPI (FastAPI) crash-loops at startup after an email-related change.

**Cause:** the chart renders `EMAIL_PROVIDER` from `email.provider`; an EMPTY string (`EMAIL_PROVIDER=""`) is rejected by the FastAPI email-backend factory on RW-1135+ images and aborts startup. The chart's own ConfigMap comment warns: "Never render EMAIL_PROVIDER='' — FastAPI factory rejects empty string."

**Fix / how the wizard avoids it:** the `email-smtp` option pins `email.provider: "smtp"` explicitly, so the wizard never emits an empty provider. If you hand-edit `email.*`, always set a non-empty `email.provider` (`smtp` or `mailgun`) — never leave it blank.

_Source: chart values.yaml `email.provider` doc + templates/configmap.yaml._
```

- [ ] **Step 7: Run the render test to verify it passes**

Run: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-email-config.sh" 2>&1 | tail -12`
Expected: `email-config: 7 passed, 0 failed` — all `email-disabled` + `email-smtp` assertions PASS.

- [ ] **Step 8: Full green-bar** (Setup block). Expected: LINT-OK (three new fragments referenced + backed); suites green except the known-red neo4j.

- [ ] **Step 9: Review checkpoint (do NOT commit yet).** Run `git add -A && git status --porcelain && git diff --cached --stat`; ASK the maintainer, then on approval:
```bash
git commit -m "feat(rwl-install-wizard): email-config axis (SMTP relay | disable + skip verification)"
```

---

## Task 2: SMTP secret-preflight item + profile fixtures + build-guide no-leak coverage

**Files:**
- Modify: `rwl-install-wizard/data/guide-sections/secret-preflight-checklist.md` (add SMTP item + verify-line token)
- Create: `rwl-install-wizard/tests/fixtures/profiles/email-smtp.yaml`
- Create: `rwl-install-wizard/tests/fixtures/profiles/email-disabled.yaml`
- Modify: `rwl-install-wizard/tests/test-build-guide.sh` (add email assertions)

**Interfaces:**
- Consumes: the `email-smtp`/`email-disabled` options + fragments from Task 1; the token `<SMTP_EXISTING_SECRET>`.

- [ ] **Step 1: Write the failing test** — append to `rwl-install-wizard/tests/test-build-guide.sh` (uses the file's existing `build_kit`/`ok`/`no`/`$FIX`), just before the final `echo`/summary line:

```bash
echo "== email-smtp profile: SMTP secret guidance rendered, no token leak =="
ES="$(build_kit "$FIX/profiles/email-smtp.yaml" values-cluster.yaml)"
if grep -qiE '&lt;(SMTP_HOST|SMTP_PORT|SMTP_TLS_MODE|SMTP_EXISTING_SECRET|EMAIL_FROM_ADDRESS)' "$ES"/*.html; then
  no "email-smtp kit leaks an unresolved token"; else ok "email-smtp kit resolves all email tokens"; fi
if grep -q 'create secret generic rw-smtp-creds' "$ES/USER-GUIDE.html"; then
  ok "email-smtp shows the SMTP secret template"; else no "email-smtp missing SMTP secret template"; fi

echo "== email-disabled profile: skip-verification security note rendered =="
ED="$(build_kit "$FIX/profiles/email-disabled.yaml" values-cluster.yaml)"
if grep -qiE 'skipEmailVerification|SKIP_EMAIL_VERIFICATION|weakens account security' "$ED/USER-GUIDE.html"; then
  ok "email-disabled shows the skip/security note"; else no "email-disabled missing skip note"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash "$PLUGIN/tests/test-build-guide.sh" 2>&1 | grep -iE "email-smtp|email-disabled|FAIL:"`
Expected: FAIL — the `email-smtp.yaml` fixture does not exist yet, so `build_kit` produces an empty/partial kit and the assertions fail.

- [ ] **Step 3: Create `rwl-install-wizard/tests/fixtures/profiles/email-smtp.yaml`** (all default-valued params filled, as the interview stores them — so nothing leaks):

```yaml
schemaVersion: 1
chartCompat: ">=0.2.37 <0.3"
generatedAt: "2026-07-21"
# Minimal profile exercising email-config=email-smtp (defaults stored for the
# default-valued params, mirroring what the interview persists).
answers:
  email-config:
    option: email-smtp
    smtpHost: smtp.corp.example
    smtpExistingSecret: rw-smtp-creds
    smtpPort: "587"
    smtpTlsMode: starttls
    emailFromAddress: noreply@corp.example
```

- [ ] **Step 4: Create `rwl-install-wizard/tests/fixtures/profiles/email-disabled.yaml`:**

```yaml
schemaVersion: 1
chartCompat: ">=0.2.37 <0.3"
generatedAt: "2026-07-21"
answers:
  email-config:
    option: email-disabled
```

- [ ] **Step 5: Add the SMTP item to `data/guide-sections/secret-preflight-checklist.md`.** Immediately AFTER the "LLM provider key" item's closing ``` fence (the block ending the `<LLM_API_KEY_SECRET>` item) and BEFORE the "Slack credentials" item, insert:

```markdown
- [ ] **SMTP credentials** — `<SMTP_EXISTING_SECRET>` (SMTP email relay only):
      ```bash
      kubectl -n <NAMESPACE> create secret generic <SMTP_EXISTING_SECRET> \
        --from-literal=EMAIL_SMTP_USERNAME='<user>' \
        --from-literal=EMAIL_SMTP_PASSWORD='<pass>'
      ```
```

Then add `<SMTP_EXISTING_SECRET>` to the final verify command's secret list (the `kubectl -n <NAMESPACE> get secret \` block) so the line reads (append it after `<SLACK_SECRET_NAME>`):

```bash
kubectl -n <NAMESPACE> get secret \
  <TLS_SECRET> <CA_BUNDLE_SECRET> \
  <S3_EXISTING_SECRET> <LLM_API_KEY_SECRET> <SLACK_SECRET_NAME> <SMTP_EXISTING_SECRET> 2>/dev/null
```

(NOTE: `<SMTP_EXISTING_SECRET>` renders literally in a kit that did NOT choose `email-smtp` because `secret-preflight-checklist` is shared — but this exact pattern already holds for `<TLS_SECRET>`/`<S3_EXISTING_SECRET>`/etc.: those tokens ALSO appear only conditionally and the checklist header already says "only the templates whose feature you enabled apply". The build-guide token-leak guard checks RAW `<...>`, and these are HTML-escaped placeholders shown intentionally, exactly like the pre-existing ones — so no new leak class is introduced. Do not attempt to make the checklist per-option conditional in this task.)

- [ ] **Step 6: Run test to verify it passes**

Run: `bash "$PLUGIN/tests/test-build-guide.sh" 2>&1 | grep -iE "email-smtp|email-disabled|passed, [0-9]+ failed"`
Expected: the email assertions PASS; `build-guide: N passed, 0 failed`.

- [ ] **Step 7: Full green-bar** (Setup block). Expected: LINT-OK; suites green except the known-red neo4j.

- [ ] **Step 8: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "test(rwl-install-wizard): email-config profile fixtures + SMTP secret checklist item"
```

---

## Task 3: SKILL.md interview step

**Files:**
- Modify: `rwl-install-wizard/skills/rwl-install/SKILL.md`

- [ ] **Step 1: Add the email bullet.** In `SKILL.md`, find the `**Registry population (Boundary 2).**` bullet in the Interview section and add, immediately after it:

```markdown
   - **Email (email-config).** Single-select. `email-smtp` requires `smtpHost` and
     `smtpExistingSecret` (hard re-prompt — required); for the default-valued
     params store the default when the operator accepts it (`smtpPort`=`587`,
     `smtpTlsMode`=`starttls`, `emailFromAddress`=`noreply@runwhen.com`) — never
     leave them blank, or their tokens leak into the overlay. `email-disabled`
     sets `papi.skipEmailVerification: "true"`: tell the operator it weakens
     account security (unverified-email login) and is for setups where that is
     acceptable.
```

- [ ] **Step 2: Verify** — `grep -n "email-config\|email-smtp\|email-disabled" "$PLUGIN/skills/rwl-install/SKILL.md"` shows the new bullet; `bash "$PLUGIN/lib/catalog-lint.sh" "$PLUGIN/data/knob-catalog.yaml" "$PLUGIN/data" && echo LINT-OK`.

- [ ] **Step 3: Full green-bar** (Setup block). Expected: unchanged (green except known-red neo4j).

- [ ] **Step 4: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "docs(rwl-install-wizard): SKILL interview step for email-config axis"
```

---

## Task 4: Version bump + hand-off

**Files:**
- Modify: `rwl-install-wizard/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump the plugin version.** In `rwl-install-wizard/.claude-plugin/plugin.json` change `"version": "0.4.0"` → `"version": "0.5.0"`.

- [ ] **Step 2: Bump the marketplace entry.** In `.claude-plugin/marketplace.json` change the `rwl-install-wizard` plugin entry's `"version": "0.4.0"` → `"version": "0.5.0"`. Leave `metadata.version` (`0.1.0`) untouched.

- [ ] **Step 3: Final full green-bar** (Setup block). Expected: LINT-OK; suites green except the known-red neo4j. Also confirm the email render test still passes: `RWL_CHART_PATH="$CHART" bash "$PLUGIN/tests/test-email-config.sh" 2>&1 | tail -2`.

- [ ] **Step 4: Review checkpoint (do NOT commit yet).** Stage, show diff, ASK maintainer, then on approval:
```bash
git commit -m "chore(rwl-install-wizard): 0.5.0 — email-config axis"
```
Then report: the commit range and remind the maintainer to push / open-or-update the PR.

---

## Notes carried from the spec (do not re-derive)

- Mailgun, `existingSecretKeys`, and `fromName` are deliberate non-goals.
- `email-disabled` only sets `skipEmailVerification`; with no provider the app already skips sends ("empty = emails skipped"), so no extra keys are needed.
- The detector renders `email-smtp`/`email-disabled` in isolation cleanly (they touch only `email.*`/`papi.*`, not the neo4j imagePullSecret path) — no detector change required.
- Verified 0.2.63 render: `email-disabled`→`SKIP_EMAIL_VERIFICATION: "true"`; `email-smtp`→`EMAIL_PROVIDER: "smtp"`, `EMAIL_SMTP_HOST/PORT/TLS_MODE`, `ACTIVITY_PROCESSOR_EMAIL_FROM_ADDRESS`, secret ref, `SKIP_EMAIL_VERIFICATION: "false"`.
