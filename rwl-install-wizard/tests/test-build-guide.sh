#!/usr/bin/env bash
# test-build-guide.sh - Unit tests for lib/build-guide.rb (deterministic HTML kit).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PLUGIN_DIR/lib/build-guide.rb"
CATALOG="$PLUGIN_DIR/data/knob-catalog.yaml"
DATA="$PLUGIN_DIR/data"
FIX="$SCRIPT_DIR/fixtures"

PASS=0; FAIL=0
ok() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
no() { printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL+1)); }

FILES="index.html USER-GUIDE.html DEBUG-GUIDE.html PREREQUISITES.html"

# Build a kit for $1=profile into a fresh dir seeded with $2... = overlay files to
# copy from the airgap expected fixture. Echoes the out dir.
build_kit() {
  local profile="$1"; shift
  local out; out="$(mktemp -d)"
  for f in "$@"; do cp "$FIX/expected/airgap/$f" "$out/" 2>/dev/null; done
  ruby "$BUILD" --catalog "$CATALOG" --profile "$profile" --data "$DATA" --out "$out" >/dev/null 2>&1
  echo "$out"
}

echo "== build-guide: ruby syntax =="
ruby -c "$BUILD" >/dev/null 2>&1 && ok "build-guide.rb parses" || { no "build-guide.rb syntax error"; }

echo "== build-guide: full airgap profile writes all four files =="
A="$(build_kit "$FIX/profiles/airgap.yaml" values-registry.yaml values-storage.yaml values-cluster.yaml)"
allfour=1; for f in $FILES; do [ -s "$A/$f" ] || allfour=0; done
[ "$allfour" = 1 ] && ok "all four HTML files written and non-empty" || no "a HTML file is missing/empty"

echo "== build-guide: DETERMINISM — same inputs produce byte-identical output =="
B="$(build_kit "$FIX/profiles/airgap.yaml" values-registry.yaml values-storage.yaml values-cluster.yaml)"
det=1; for f in $FILES; do diff -q "$A/$f" "$B/$f" >/dev/null 2>&1 || det=0; done
[ "$det" = 1 ] && ok "two runs are byte-identical (predictable uniformity)" || no "output differs across runs"

echo "== build-guide: every command block has a copy button =="
cmds=$(grep -o 'class="cmd"' "$A"/*.html | wc -l | tr -d ' ')
copies=$(grep -o 'class="copy"' "$A"/*.html | wc -l | tr -d ' ')
[ "$cmds" = "$copies" ] && [ "$cmds" -gt 0 ] && ok "copy buttons match command blocks ($cmds)" \
  || no "copy/command mismatch (cmd=$cmds copy=$copies)"

echo "== build-guide: self-contained (no external asset refs) =="
if grep -Eq '(src|href)="https?://' "$A"/*.html; then
  no "an HTML file references an external URL asset"
else ok "no external asset references (opens offline)"; fi

echo "== build-guide: composed -f names only the written overlays =="
gate="$(cat "$A/PREREQUISITES.html")"
if echo "$gate" | grep -q -- '-f values-cluster.yaml' \
   && echo "$gate" | grep -q -- '-f values-registry.yaml' \
   && ! echo "$gate" | grep -q -- '-f values-posture.yaml'; then
  ok "render-gate lists written overlays, omits the un-generated one"
else no "render-gate -f composition wrong"; fi

echo "== build-guide: substitutes known params, keeps install-time fills literal =="
grep -q 'artifactory.corp.example' "$A/USER-GUIDE.html" && ok "answered param value substituted (registryHost)" \
  || no "answered param not substituted"
grep -q '&lt;RELEASE&gt;' "$A/USER-GUIDE.html" && grep -q '&lt;NAMESPACE&gt;' "$A/USER-GUIDE.html" \
  && ok "install-time fills (<RELEASE>/<NAMESPACE>) left literal" || no "install-time fills were wrongly resolved"

echo "== build-guide: no bare unescaped <TOKEN> leaks into markup =="
if grep -Eq '<[A-Z][A-Z0-9_]{2,}>' "$A"/*.html; then
  no "a bare uppercase <TOKEN> leaked unescaped"
else ok "all tokens escaped or substituted (no raw <TOKEN>)"; fi

echo "== build-guide: empty-answers profile still writes all guides WITH fallbacks =="
EMPTY="$(mktemp)"
printf 'schemaVersion: 1\nchartCompat: ">=0.2.37 <0.3"\ngeneratedAt: "2026-07-14"\nanswers: {}\n' > "$EMPTY"
E="$(build_kit "$EMPTY")"
efour=1; for f in $FILES; do [ -s "$E/$f" ] || efour=0; done
[ "$efour" = 1 ] && ok "all four files written for an empty profile (always-write)" || no "a file missing for empty profile"
grep -q 'No known issues' "$E/DEBUG-GUIDE.html" && ok "DEBUG-GUIDE has fallback body when no issues apply" \
  || no "DEBUG-GUIDE missing fallback body"
grep -q 'No option-specific cluster prerequisites' "$E/PREREQUISITES.html" \
  && ok "PREREQUISITES has fallback body when no prereqs apply" || no "PREREQUISITES missing fallback body"
grep -q 'No guided install sections' "$E/USER-GUIDE.html" && ok "USER-GUIDE has fallback body when no sections apply" \
  || no "USER-GUIDE missing fallback body"

echo "== registry-auth WI profile: no pull-secret guidance, WI section present =="
W="$(build_kit "$FIX/profiles/airgap-wi.yaml" values-registry.yaml)"
if grep -qi 'Workload Identity' "$W/USER-GUIDE.html"; then ok "WI profile renders the Workload-Identity guidance"; else no "WI profile missing Workload-Identity section"; fi
if grep -qiE 'create secret docker-registry|PULL_SECRET_NAME' "$W/USER-GUIDE.html"; then no "WI profile still shows pull-secret creation guidance (should be omitted)"; else ok "WI profile omits pull-secret creation guidance"; fi

echo "== build-guide: HTML is valid enough — doctype + closed body/html =="
head -1 "$A/index.html" | grep -qi '<!doctype html>' && grep -q '</html>' "$A/index.html" \
  && ok "index.html has doctype and closes" || no "index.html malformed"

echo ""
echo "build-guide: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
