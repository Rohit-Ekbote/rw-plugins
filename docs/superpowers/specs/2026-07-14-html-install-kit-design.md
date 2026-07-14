# Design: deterministic HTML install-kit

Date: 2026-07-14
Status: approved (maintainer), pending implementation + verification gate

## Problem

The wizard's generated docs (`USER-GUIDE.md`, `DEBUG-GUIDE.md`,
`PREREQUISITES.md`) are assembled by the LLM at GENERATE time. Two consequences:

1. **No run-to-run uniformity.** Free-form LLM assembly drifts in structure,
   ordering, and wording across runs of the same profile.
2. **Weak always-write guarantee.** Only `PREREQUISITES.md` is spec'd to always
   write (with a fallback); the two guides have no explicit fallback.

We want: HTML output with copy-to-clipboard command buttons, and predictable
uniformity across runs.

## Decision

Add a deterministic assembler `lib/build-guide.rb` (pure Ruby 2.6, no gems) that
produces the HTML kit from the profile + catalog + `data/*.md` fragments. The
SKILL calls it instead of hand-assembling. All LLM variance in doc output is
removed; the guides always write, with fallbacks.

## Output (`rwl-install-out/`)

```
index.html          landing: links to the guides + list of generated overlays
USER-GUIDE.html      union of guide_sections (catalog order) + composed helm cmds
DEBUG-GUIDE.html     union of known_issues            (fallback body if none)
PREREQUISITES.html   union of prereqs + pre-flight render gate  (always)
values-*.yaml        unchanged (YAML, still SKILL-generated)
```

All three guides are always written with a fallback body — enforced by the
script.

## `lib/build-guide.rb`

Inputs: `--catalog <knob-catalog.yaml>`, `--profile <profile.yaml>`,
`--data <data/>`, `--out <rwl-install-out/>`.

1. Parse profile → answered options (single = hash, multi = list), in catalog
   declaration order. Guide/known-issue/prereq unions follow catalog order
   (fragments carry no phase metadata; catalog order ≈ install-checklist order).
2. **Scan `--out` for `values-*.yaml`** already written by the SKILL → compose
   every `helm … -f …` command from the overlays that exist, in apply order
   (`values.yaml → registry → storage → cluster → posture`). One `-f` per line.
3. **Substitution engine.** Build a map:
   - Mechanical: `SCREAMING_SNAKE(paramId)` → operator value, for every answered
     non-blank param (32 of 42 fragment tokens are mechanical).
   - Explicit dictionary for the 10 non-mechanical tokens:
     - `CHART_COMPAT` → `profile.chartCompat`
     - `RELEASE` → answered `releaseName` if present, else LITERAL
     - `REGISTRY_HOST_ONLY` → `registryHost` with any `/path` stripped
     - `NAMESPACE`, `CHART_REF`, `CHART_VERSION`, `ENV_VAR_IN_SECRET`,
       `ENV_VAR_NAME`, `VAR`, `VAR_NAME` → LITERAL (install-time / illustrative
       operator-fills; never substituted, never dropped)
   - Rule: a token whose `SCREAMING_SNAKE` matches a catalog param but is
     unanswered/blank in this profile → **drop the smallest enclosing block**
     (paragraph, list item, or fenced block) so no dangling token renders.
     LITERAL-dictionary tokens and lowercase illustrative tokens (`<release>`,
     `<domain>`) are kept verbatim. Secret VALUES are never substituted.
4. **Markdown → HTML** for the bounded subset the fragments use: headings h1–h4,
   paragraphs, `**bold**`, inline `` `code` ``, links `[t](u)` (1 use),
   unordered + ordered lists, GFM tables, blockquotes, fenced code blocks. Each
   fenced block becomes a copy widget (button + `<pre>`).
5. Wrap each document body in the boilerplate shell and write the file.

## Boilerplate (uniformity guarantee)

Versioned constants in `build-guide.rb`: inline CSS + copy JS + page shell. Fully
self-contained (no external assets → opens offline). Clean neutral: system font,
~70ch measure, styled code blocks, `prefers-color-scheme` light/dark. Identical
chrome every run.

## Touchpoints

- **`skills/rwl-install/SKILL.md`** — GENERATE step 5.2–5.4 collapse into a single
  `build-guide.rb` call after overlays are written; `.md` → `.html`; note the
  always-write-with-fallback is now enforced by the script.
- **`lib/secret-guard.sh`** — add `*.html` to its `find` (else HTML output is not
  scanned — a safety regression). Gate still runs over `rwl-install-out/`.
- **`skills/rwl-install-show/SKILL.md`** — `.md` → `.html` for the three guides.
  (`rwl-install-explain` references only `data/*.md` source fragments — unchanged.)

## Tests

- **Determinism**: run `build-guide.rb` twice on a fixture profile → byte-identical
  output. This is the uniformity gate.
- **Golden fixture**: commit expected HTML for one profile; diff it.
- **Invariants**: every fenced command block has a copy button; no dangling *known*
  `<TOKEN>`; LITERAL tokens (`<NAMESPACE>`, `<PLACEHOLDER>`, illustrative) preserved;
  all 4 files exist even for a minimal profile; zero external-asset references.
- **Placeholder-drift lint** (optional): every uppercase `<TOKEN>` used in a
  fragment is either mechanical (matches a catalog param) or in the explicit
  dictionary — catches a new fragment introducing an unmapped token.

## Out of scope (YAGNI)

Overlays stay YAML. No syntax highlighting, search, or multi-page nav beyond the
index.

## Not done here

Never commits; maintainer reviews and commits. `plugin.json` version call
(stay 0.3.0 vs → 0.4.0) left to the maintainer at hand-off.
