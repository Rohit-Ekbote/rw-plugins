# Design: `email-config` axis (SMTP email + skip-verification)

Date: 2026-07-21
Status: approved (maintainer), pending implementation + verification gate

## Problem

The catalog has no email knob. The `runwhen-platform` chart defaults
`papi.skipEmailVerification: "false"` — email verification is **enforced** — so an
operator who configures no email provider and does not skip verification locks
users out (no verification email can be sent, no login/signup). Operators need a
guided choice: configure an email server, or disable email and turn verification
off so accounts can be used.

## Decision

Add a top-level single-select axis `email-config`, modeled on `llm-endpoint`,
overlaying into `values-cluster.yaml`. Two options: configure an **SMTP relay**, or
**disable** email (skip verification). Mailgun (the chart's other provider) is out
of scope — it is a SaaS API needing internet egress, unusable in the self-hosted /
air-gap installs the wizard targets.

Verified against chart **0.2.63** (render ground truth):
- `papi.skipEmailVerification: "true"` → PAPI ConfigMap `SKIP_EMAIL_VERIFICATION: "true"`.
- `email.provider: smtp` + `email.smtp.{host,port,tlsMode,existingSecret}` +
  `email.fromAddress` → `EMAIL_PROVIDER: "smtp"`, `EMAIL_SMTP_HOST/PORT/TLS_MODE`,
  `ACTIVITY_PROCESSOR_EMAIL_FROM_ADDRESS`, and a `secretKeyRef`/`envFrom` to the
  named Secret. The chart comments "Never render EMAIL_PROVIDER='' — FastAPI
  factory rejects empty string", so the emit pins `provider: "smtp"` explicitly.

## Changes

### New axis `email-config` (single-select, inserted after `llm-endpoint`)

Overlays into `values-cluster.yaml`.

#### Option `email-smtp`

Params:
- `smtpHost` — **required** (hard re-prompt). SMTP relay hostname.
- `smtpExistingSecret` — **required**. Name of a pre-created Secret in the release
  namespace holding `EMAIL_SMTP_USERNAME` / `EMAIL_SMTP_PASSWORD` (secret-free —
  wired by name only). May also carry `EMAIL_PROVIDER=smtp`.
- `smtpPort` — default `587`. Prompt notes 587=STARTTLS / 465=SSL / 25=none.
- `smtpTlsMode` — default `starttls` (`starttls` | `ssl` | `none`).
- `emailFromAddress` — default `noreply@runwhen.com` (the chart's own default sender).

Emits:
```yaml
email:
  provider: "smtp"
  fromAddress: "<EMAIL_FROM_ADDRESS>"
  smtp:
    host: "<SMTP_HOST>"
    port: "<SMTP_PORT>"
    tlsMode: "<SMTP_TLS_MODE>"
    existingSecret: "<SMTP_EXISTING_SECRET>"
papi:
  skipEmailVerification: "false"
```

`guide_sections: [email-smtp, secret-preflight-checklist]`. No `prereqs` beyond the
secret (the checklist covers it). `known_issues: [email-empty-provider-crash]`.

#### Option `email-disabled`

No params. Emits:
```yaml
papi:
  skipEmailVerification: "true"
```

`guide_sections: [email-disabled]`. `known_issues: []`.

### Leak-safe optional-param handling

`build-guide.rb`'s `substitution_map` drops blank params (`next if s.strip.empty?`),
so a bare `<TOKEN>` for an unset param renders literally in the overlay. Therefore
every param that appears as a token in the `email-smtp` emit must ALWAYS carry a
value in the profile:
- `smtpHost`, `smtpExistingSecret`: required → always answered.
- `smtpPort`, `smtpTlsMode`, `emailFromAddress`: **default-valued** — the interview
  stores the default (`587` / `starttls` / `noreply@runwhen.com`) when the operator
  does not override, so `<SMTP_PORT>` / `<SMTP_TLS_MODE>` / `<EMAIL_FROM_ADDRESS>`
  always resolve. `SKILL.md` must state that these three default-valued params are
  stored (not left blank) when accepted.

### Token map (screaming-snake of the param ids)

Param ids are chosen so `screaming(id)` matches the emit tokens exactly:
`smtpHost`→`<SMTP_HOST>`, `smtpExistingSecret`→`<SMTP_EXISTING_SECRET>`,
`smtpPort`→`<SMTP_PORT>`, `smtpTlsMode`→`<SMTP_TLS_MODE>`,
`emailFromAddress`→`<EMAIL_FROM_ADDRESS>`. Implementation must verify each token
against `screaming`'s actual output (camelCase→UPPER_SNAKE).

### New guide fragments

- `data/guide-sections/email-smtp.md` — what the option sets; the required BYO
  Secret and its keys, with a secret-free `kubectl create secret generic
  <SMTP_EXISTING_SECRET> --from-literal=EMAIL_SMTP_USERNAME='<user>'
  --from-literal=EMAIL_SMTP_PASSWORD='<pass>'` template (placeholders only); note
  that `<SMTP_PORT>`/`<SMTP_TLS_MODE>` must match the relay; single-line bullets
  (renderer joins continuations, but keep them simple).
- `data/guide-sections/email-disabled.md` — states it sets
  `SKIP_EMAIL_VERIFICATION=true` so accounts sign up/log in without a verified
  email; **security warning** (chart calls it a dev convenience — unverified-email
  login is acceptable only where that risk is understood).

### `secret-preflight-checklist.md` gains an SMTP item

Add an "SMTP credentials" item keyed on `<SMTP_EXISTING_SECRET>` (only rendered
when the operator chose `email-smtp`, since it participates via that option's
`guide_sections`), mirroring the existing TLS/CA/S3/LLM/Slack items:
```bash
kubectl -n <NAMESPACE> create secret generic <SMTP_EXISTING_SECRET> \
  --from-literal=EMAIL_SMTP_USERNAME='<user>' \
  --from-literal=EMAIL_SMTP_PASSWORD='<pass>'
```
Also add `<SMTP_EXISTING_SECRET>` to the checklist's final `kubectl get secret`
verify line.

### New known-issue `email-empty-provider-crash.md`

Symptom→cause→fix: an empty `EMAIL_PROVIDER` env crashes FastAPI (PAPI) at startup
(the chart's own ConfigMap comment); the `email-smtp` option pins `provider:
"smtp"` so this never happens via the wizard. Documented so an operator hand-editing
the overlay understands the constraint.

### `SKILL.md` interview step

Add an `**Email (email-config).**` bullet: single-select; `email-smtp` requires
`smtpHost` + `smtpExistingSecret` (hard re-prompt), and stores defaults for
`smtpPort`/`smtpTlsMode`/`fromAddress` when accepted; `email-disabled` weakens
account security (skip verification) — surface that to the operator.

## Non-goals

- **Mailgun provider** — SaaS, needs egress; out of scope for self-hosted/air-gap.
  Deferrable to a later `email-mailgun` option if demand appears.
- **`existingSecretKeys` custom key mapping** — the option assumes the standard
  Secret keys (`EMAIL_SMTP_USERNAME`/`PASSWORD`). Operators with non-standard key
  names hand-edit; not modeled.
- **`fromName`** — the chart default ("RunWhen Notifications") is fine; not
  collected.
- **Disabling all outbound email sends** — `email-disabled` only sets
  `skipEmailVerification`; it configures no provider, so `EMAIL_PROVIDER` falls to
  the chart default (`mailgun`) and sends are skipped for lack of Mailgun
  credentials — no empty-provider crash, no extra keys needed.

## Testing / verification gate

- **Render-gate against the vendored 0.2.63 chart** for both options:
  - `email-disabled` → PAPI ConfigMap `SKIP_EMAIL_VERIFICATION: "true"`.
  - `email-smtp` → `EMAIL_PROVIDER: "smtp"`, `EMAIL_SMTP_HOST/PORT/TLS_MODE`,
    `ACTIVITY_PROCESSOR_EMAIL_FROM_ADDRESS`, a Secret ref to `<SMTP_EXISTING_SECRET>`,
    and `SKIP_EMAIL_VERIFICATION: "false"`; exit 0, no fail-fast.
- **`build-guide` no-token-leak**: a profile answering `email-smtp` (with defaults
  accepted) renders no literal `<SMTP_*>` / `<FROM_ADDRESS>` in the HTML — covered
  by the existing escaped-token guard plus a targeted assertion; add an
  `email-smtp` and an `email-disabled` profile fixture.
- **`catalog-lint`** clean: the three new fragments (`email-smtp`, `email-disabled`,
  known-issue `email-empty-provider-crash`) referenced + backed; no orphans.
- **`RWL_CHART_PATH=<0.2.63> run-all.sh`** green apart from the pre-existing
  known-red neo4j chart-bug test.
- **Detector**: `email-config` is a new top-level axis with no `dependsOn`; its
  options render in isolation cleanly (they touch only `email.*` / `papi.*`, not the
  neo4j imagePullSecret path), so no detector change is needed.

## Sequencing

Single, self-contained axis — one implementation plan, TDD per fragment/option,
each step ending green on `catalog-lint` + the render-gate + `run-all.sh`. Bump
`plugin.json` + `marketplace.json` (`0.4.0` → `0.5.0`, a new feature).
