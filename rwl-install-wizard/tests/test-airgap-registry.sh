#!/usr/bin/env bash
# test-airgap-registry.sh — Regression guard for the air-gap install kit.
#
# Ground-truth review (v0.1.2) found the generated air-gap values were NOT
# installable. This guard asserts the fixes against the WORKING reference
# (infra-flux .../airgap/runwhen-platform/helmrelease.yaml) + the chart schema:
#
#   MISSED-1  no registryOverride; per-upstream, path-preserving image refs so
#             overlay == image-manifest push targets; no public registry survives.
#   MISSED-2  seaweedfs.s3.existingConfigSecret == <release>-seaweedfs-identities.
#   MISSED-3  metricstore.persistence.storageClassName (not the ignored storageClass).
#   MISSED-4  every stateful component (spilo/vault/neo4j/redis) wired to the class.
#   MISSED-5  llmBootstrap emitted (LLM stack seeded, not inert).
#   MISSED-6  codeCollections + cc-catalog sources repointed at the mirror.
#   MISSED-7  ccCatalog.auth.dockerconfigjsonSecret emitted.
#
# Static checks always run (no helm needed). The RENDER check runs when a chart
# is available (env RWL_CHART_PATH, else a known local path) — it `helm template`s
# the fixtures with a NON-`rw` release and asserts zero public/unresolved image
# refs and no validate fail-fast (the check the old public-host grep couldn't do).
#
# bash 3.2 compatible (macOS default). No YAML parser.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CATALOG="$PLUGIN_DIR/data/knob-catalog.yaml"
MANIFEST="$PLUGIN_DIR/data/guide-sections/airgap-image-manifest.md"
AIRGAP="$SCRIPT_DIR/fixtures/expected/airgap"
REG="$AIRGAP/values-registry.yaml"
STO="$AIRGAP/values-storage.yaml"
CLU="$AIRGAP/values-cluster.yaml"

PASS=0; FAIL=0
ok(){ printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL+1)); }
has(){ grep -qF "$2" "$1"; }   # has <file> <literal>

option_block() {
  awk -v want="$1" '
    function fns(s){ return match(s, /[^ ]/) ? RSTART-1 : length(s) }
    {
      if ($0 ~ /^[[:space:]]*-[[:space:]]+id:[[:space:]]*/) {
        ind=fns($0); t=$0
        sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", t); sub(/[[:space:]].*$/, "", t)
        if (cap && ind<=start) cap=0
        if (t==want) { cap=1; start=ind; print; next }
      }
      if (cap) print
    }' "$CATALOG"
}

# Public hosts that must never survive into an air-gap overlay (git URLs excluded).
PUBLIC_HOSTS='us-docker\.pkg\.dev|ghcr\.io|quay\.io|registry-1\.docker\.io|docker\.io|registry\.k8s\.io|registry\.suse\.com'
no_public() {   # no_public <file> <label>
  if grep -nE "$PUBLIC_HOSTS" "$1" | grep -vE 'git_url|repoUrl|github\.com' >/dev/null; then
    no "$2 leaks a public registry host"; else ok "$2 has no public registry host"; fi
}

# Match the emitted KEY only (strip comment lines first — the removal rationale
# legitimately names registryOverride in prose).
nocomment(){ grep -vE '^[[:space:]]*#' "$1"; }

echo "== MISSED-1 (revised): per-source overlays never use registryOverride; flat does, with its own manifest =="
if grep -q 'id: mirrored-per-upstream' "$CATALOG"; then ok "mirrored-per-upstream option present"; else no "mirrored-per-upstream option missing"; fi
# Per-source is still path-preserving and must NEVER set registryOverride.
persrc="$(option_block mirrored-per-upstream)"
if grep -qE 'registryOverride[[:space:]]*:' <<<"$persrc"; then no "mirrored-per-upstream must not set registryOverride"; else ok "mirrored-per-upstream never sets registryOverride"; fi
if grep -qE 'registryOverride[[:space:]]*:' <<<"$(nocomment "$REG")"; then no "per-source fixture values-registry.yaml sets registryOverride"; else ok "per-source fixture has no registryOverride"; fi
# Flat is now a supported layout and MUST pair registryOverride with its flat manifest.
flat="$(option_block flat-mirror | grep -vE '^[[:space:]]*#')"
if grep -qE 'registryOverride[[:space:]]*:' <<<"$flat"; then ok "flat-mirror uses registryOverride (expected for flat layout)"; else no "flat-mirror missing registryOverride"; fi
if grep -q 'airgap-image-manifest-flat' <<<"$flat"; then ok "flat-mirror references the flat image manifest"; else no "flat-mirror must reference airgap-image-manifest-flat (MISSED-1 guard: no flat overlay without a flat manifest)"; fi

echo "== FLAT: fixture is fully on the flat prefix, no public host =="
FLATREG="$SCRIPT_DIR/fixtures/expected/flat/values-registry.yaml"
if [ -f "$FLATREG" ]; then
  if grep -nE "$PUBLIC_HOSTS" "$FLATREG" | grep -vE 'git_url|repoUrl|github\.com' >/dev/null; then no "flat fixture leaks a public host"; else ok "flat fixture has no public host"; fi
  grep -qE 'registryOverride: "?flatreg\.example/rw-virtual"?' "$FLATREG" && ok "flat fixture sets registryOverride" || no "flat fixture missing registryOverride"
else no "flat fixture missing"; fi

echo "== AUTH: registry-auth axis owns pull-secret keys =="
# The pull-secret keys must NO LONGER be inline on the layout option; they live on
# registry-auth=pull-secret. The layout option must not carry pullSecrets itself.
layout_block="$(option_block mirrored-per-upstream | nocomment /dev/stdin)"
if grep -qE 'pullSecrets|dockerconfigjsonSecret|imagePullSecrets' <<<"$layout_block"; then
  no "mirrored-per-upstream still carries pull-secret keys inline (should move to registry-auth)"
else ok "mirrored-per-upstream carries no pull-secret keys"; fi
authps_block="$(option_block pull-secret | nocomment /dev/stdin)"
for k in "images:" "pullSecrets:" "imagePullSecrets:" "dockerconfigjsonSecret:"; do
  if grep -qF "$k" <<<"$authps_block"; then ok "registry-auth=pull-secret emits $k"; else no "registry-auth=pull-secret missing $k"; fi
done
authwi_block="$(option_block workload-identity | nocomment /dev/stdin)"
if grep -qE 'pullSecrets|imagePullSecrets|dockerconfigjsonSecret' <<<"$authwi_block"; then
  no "workload-identity emits pull-secret keys (must be secret-free)"; else ok "workload-identity is secret-free"; fi

echo "== AUTH: workload-identity fixture is secret-free but fully mirrored =="
WIREG="$SCRIPT_DIR/fixtures/expected/wi-persource/values-registry.yaml"
if [ -f "$WIREG" ]; then
  no_public "$WIREG" "wi-persource values-registry.yaml"
  if grep -qE 'pullSecrets|imagePullSecrets|dockerconfigjsonSecret' <<<"$(grep -vE '^[[:space:]]*#' "$WIREG")"; then
    no "wi-persource overlay contains pull-secret keys (must be secret-free)"; else ok "wi-persource overlay is secret-free"; fi
  if grep -q 'disableLookups: true' "$WIREG"; then ok "wi-persource keeps neo4j disableLookups (MISSED-10)"; else no "wi-persource dropped neo4j disableLookups"; fi
else no "wi-persource fixture missing"; fi

echo "== MISSED-1: overlays keep every image on the mirror (per-upstream paths) =="
no_public "$REG" "values-registry.yaml"
for ref in \
  "artifactory.corp.example/docker-runwhen-self-hosted/runwhen-self-hosted/platform-images" \
  "artifactory.corp.example/docker-ghcr/runwhen-contrib" \
  "artifactory.corp.example/docker-ghcr/berriai" \
  "artifactory.corp.example/docker-ghcr/zalando" \
  "artifactory.corp.example/docker-dockerhub/library/neo4j:5.26.28-ubi10" \
  "artifactory.corp.example/docker-suse/bci/bci-base:15.7"; do
  if has "$REG" "$ref"; then ok "per-upstream ref present: ${ref##*/}"; else no "missing per-upstream ref: $ref"; fi
done

echo "== N1 pinned tags: self-warning + match manifest baseline =="
if has "$REG" "x-airgap-pinned-tags-notice" && has "$REG" "Chart.lock"; then ok "overlay carries the pinned-tags verify warning"; else no "overlay missing pinned-tags verify warning"; fi
for pair in "5.26.28-ubi10 library/neo4j:5.26.28-ubi10" "2.0.3 hashicorp/vault:2.0.3" "15.7 bci/bci-base:15.7"; do
  set -- $pair; ver="$1"; mref="$2"
  if has "$REG" "$ver" && has "$MANIFEST" "$mref"; then ok "pinned $ver matches manifest ($mref)"; else no "pinned $ver does not match manifest baseline"; fi
done

echo "== MISSED-2: seaweedfs identities pinned to <release>-seaweedfs-identities =="
if has "$STO" "rw-airgap-seaweedfs-identities"; then ok "seaweedfs.s3.existingConfigSecret set to release-scoped identities Secret"; else no "seaweedfs identities Secret not wired (validate will fail-fast)"; fi

echo "== MISSED-3/4: storage classes wired via the correct keys =="
if grep -q 'storageClassName' <<<"$(grep -A4 'metricstore:' "$STO")"; then ok "metricstore uses persistence.storageClassName"; else no "metricstore still uses the ignored storageClass key"; fi
for probe in "spilo:" "dataStorage:" "mode: dynamic" "master:"; do
  if has "$STO" "$probe"; then ok "storage wires component ($probe)"; else no "storage missing component override ($probe)"; fi
done
if [ "$(grep -c 'standard-rwo' "$STO")" -ge 8 ]; then ok "chosen StorageClass wired into every stateful component"; else no "StorageClass not wired into all components"; fi

echo "== MISSED-5/8: llmBootstrap + model_info.mode =="
for probe in "llmBootstrap:" "provider:" "dimension: 1536" "mode: chat" "mode: embedding"; do
  if has "$CLU" "$probe"; then ok "llm overlay has $probe"; else no "llm overlay missing $probe"; fi
done

echo "== MISSED-6/7: codeCollections + cc-catalog repointed; ccCatalog auth =="
if has "$REG" "dockerconfigjsonSecret: jcr-pull-secret"; then ok "ccCatalog.auth.dockerconfigjsonSecret wired"; else no "ccCatalog auth secret missing"; fi
if grep -q 'ghcr\.io' <<<"$(grep -E 'imageRegistry:|image_registry:' "$REG")"; then no "codecollection registry still public ghcr.io"; else ok "every codecollection registry points at the mirror"; fi
no_public "$STO" "values-storage.yaml"; no_public "$CLU" "values-cluster.yaml"

echo "== RENDER (oracle): helm template fixtures with a NON-rw release =="
CHART="${RWL_CHART_PATH:-/Users/rohitekbote/wd/code/github.com/runwhen/rwlight-helm/charts/runwhen-platform}"
if command -v helm >/dev/null 2>&1 && [ -f "$CHART/Chart.yaml" ]; then
  TMP="$(mktemp)"
  # RENDER THE GENERATED OVERLAYS VERBATIM. Never pass --set values the plugin
  # does not emit — a --set crutch here is exactly what let MISSED-10 ship green
  # (the overlay omitted neo4j.disableLookups while the test injected it). The
  # overlays must render as an operator installs them, with no extra flags.
  if helm template rw-airgap "$CHART" -f "$CHART/values.yaml" -f "$REG" -f "$STO" -f "$CLU" >"$TMP" 2>"$TMP.err"; then
    ok "helm template succeeds (non-rw release; no validate fail-fast)"
    if has "$CLU" "kind: spilo"; then ok "[6] airgap cluster overlay pins postgresql.kind: spilo"; else no "[6] airgap overlay does not pin postgresql.kind: spilo"; fi
    if grep -nE '(image|customImage): *"?('"$PUBLIC_HOSTS"')' "$TMP" >/dev/null; then
      no "rendered manifests contain a public image ref"; else ok "every rendered image ref is on the mirror"; fi
    # value-at-consumer: airgap profile (only llmBaseUrl -> api_base applies; datastores are bundled)
    if ruby "$PLUGIN_DIR/lib/check-consumers.rb" "$CATALOG" "$SCRIPT_DIR/fixtures/profiles/airgap.yaml" "$TMP" >/dev/null 2>&1; then
      ok "airgap: every operator input reaches its consumer"
    else no "airgap: an operator input did not reach its declared consumer"; fi
  else
    no "helm template FAILED: $(head -1 "$TMP.err")"
  fi
  # byo-datastores must ALSO render verbatim — external datastores layered with
  # the storage + cluster overlays. Exercises vault.external.address, whose flat
  # `vault.address` shape nil-pointered on the webhooks/agentfarm/csi templates
  # (the render guard only covered the bundled-datastores profile before). Uses
  # only plugin-emitted fixtures; NO --set.
  BYO="$(dirname "$AIRGAP")/byo-datastores/values-cluster.yaml"
  if helm template rw-airgap "$CHART" -f "$CHART/values.yaml" -f "$STO" -f "$CLU" -f "$BYO" >"$TMP" 2>"$TMP.err"; then
    # Assert the VALUE at each consumer, NOT mere presence. MISSED-11: the external
    # address appeared on csi-secret-class while VAULT_URL/RUNNER_VAULT_URL silently
    # resolved to https://vault.<domain> (the plugin set only vault.external.*, but the
    # chart reads flat vault.address / vault.runnerAddress for those). A bare
    # `grep vault.example.com` passed on the csi occurrence alone and hid it.
    vok=1
    grep -q 'VAULT_URL: "https://vault.example.com"' "$TMP" || vok=0
    grep -q 'RUNNER_VAULT_URL: "https://vault.example.com"' "$TMP" || vok=0
    grep -q 'vault\.airgap\.example\.com' "$TMP" && vok=0   # no domain-derived host may leak
    [ "$vok" = 1 ] && ok "byo-datastores: VAULT_URL + RUNNER_VAULT_URL resolve to the external Vault" \
                   || no "byo-datastores: a Vault URL does not resolve to the operator's external address"
    cc_out="$(ruby "$PLUGIN_DIR/lib/check-consumers.rb" "$CATALOG" "$SCRIPT_DIR/fixtures/profiles/byo.yaml" "$TMP" 2>&1)"
    if [ $? -eq 0 ]; then
      ok "byo: every operator input (vault/pg/redis/neo4j/llm) reaches its consumer"
    else
      # KNOWN-ISSUE RED (data/known-issues/neo4j-external-agentfarm-usearch.md): with
      # external Neo4j the chart hardcodes the bundled neo4j host into agentfarm/usearch
      # NEO4J_URI/GRAPH_DB_URI, so those consumers never reflect the operator's neo4jUri.
      # EXPECTED to fail until the rwlight-helm chart is fixed. Split known vs new so a
      # SECOND consumer regression emits its OWN failure and moves the pass/fail tally —
      # the known red must not mask a new one.
      failed="$(printf '%s\n' "$cc_out" | awk '/FAIL:/{print $2}' | tr -d ':' | sort -u | grep -v '^$')"
      if grep -qx 'neo4jUri' <<<"$failed"; then
        no "byo: KNOWN neo4jUri consumer red (chart bug neo4j-external-agentfarm-usearch)"
      fi
      unexpected="$(printf '%s\n' "$failed" | grep -vx 'neo4jUri' | grep -v '^$' | tr '\n' ' ')"
      [ -n "$unexpected" ] && no "byo: UNEXPECTED consumer regression (not the known issue): $unexpected"
    fi
  else
    no "byo-datastores helm template FAILED: $(head -1 "$TMP.err")"
  fi
  echo "== RENDER (oracle): STOXX hardened repro — llm off + spilo + snippets off =="
  SX="$SCRIPT_DIR/fixtures/expected/stoxx-hardened"
  if helm template rw-stoxx "$CHART" -f "$CHART/values.yaml" \
       -f "$SX/values-cluster.yaml" -f "$SX/values-storage.yaml" -f "$SX/values-posture.yaml" \
       >"$TMP" 2>"$TMP.err"; then
    ok "[1] STOXX combo renders (llmGateway.deploy:false → no model_list fail-fast)"
    # [5] the Spilo container must NOT inherit the global readOnlyRootFilesystem:true.
    if grep -q 'readOnlyRootFilesystem: false' "$TMP"; then ok "[5] Spilo container relaxes readOnlyRootFilesystem"; else no "[5] Spilo readOnlyRootFilesystem override did not reach the render"; fi
    # [4] runner-metric-proxy Ingress renders without snippets.
    if grep -q 'kind: Ingress' "$TMP" && grep -q 'runner-metrics' "$TMP"; then ok "[4] runner-metric-proxy Ingress rendered without snippets"; else no "[4] runner-metric-proxy Ingress missing under snippets-blocked"; fi
  else
    no "[1/4/5] STOXX hardened combo FAILED to render: $(head -1 "$TMP.err")"
  fi
  echo "== RENDER (oracle): Gateway API routing — chart-managed Gateway (routing-mode axis) =="
  # The routing-mode split makes gatewayClassRouting emit ingress.type=gateway +
  # gateway.gatewayClassName. Assert the chart renders a Gateway carrying the
  # operator's GatewayClass, HTTPRoutes, and NO Ingress objects — the exact
  # behavior the old gatewayApi stub (global.domain only) failed to produce.
  # llmGateway.deploy:false lives in the overlay (a valid operator config), NOT as
  # a --set crutch, per the render-verbatim rule above.
  GWOV="$(mktemp)"
  cat > "$GWOV" <<'YML'
global:
  domain: rw.example.com
ingress:
  enabled: true
  type: gateway
  gateway:
    gatewayClassName: test-gwclass
llmGateway:
  deploy: false
# Satisfy the unrelated seaweedfs identities invariant (MISSED-2) for this
# non-rw release, exactly as a real kit's storage overlay does — keeps this
# render focused on routing, not object storage.
seaweedfs:
  s3:
    existingConfigSecret: rw-gw-seaweedfs-identities
YML
  if helm template rw-gw "$CHART" -f "$CHART/values.yaml" -f "$GWOV" >"$TMP" 2>"$TMP.err"; then
    gwok=1
    grep -qE '^kind: Gateway$' "$TMP" || gwok=0
    grep -q 'gatewayClassName: "test-gwclass"' "$TMP" || gwok=0   # operator input reaches the Gateway
    grep -qE '^kind: HTTPRoute$' "$TMP" || gwok=0
    grep -qE '^kind: Ingress$' "$TMP" && gwok=0                    # gateway mode leaves no Ingress
    [ "$gwok" = 1 ] && ok "gatewayClassRouting: Gateway(gatewayClassName)+HTTPRoutes render, no Ingress" \
                    || no "gatewayClassRouting: gateway render missing Gateway/HTTPRoute or leaked Ingress"
  else
    no "gatewayClassRouting FAILED to render: $(head -1 "$TMP.err")"
  fi
  rm -f "$GWOV"
  rm -f "$TMP" "$TMP.err"
else
  echo "  SKIP: chart not found at \$RWL_CHART_PATH ($CHART) — static checks only"
fi

echo "== POPULATION: registry-population axis exists, guide-only =="
if grep -q 'id: registry-population' "$CATALOG"; then ok "registry-population axis present"; else no "registry-population axis missing"; fi
pop_cache="$(option_block cache)"; pop_expl="$(option_block explicit-mirror)"
for pair in "cache:$pop_cache" "explicit-mirror:$pop_expl"; do
  nm="${pair%%:*}"; blk="${pair#*:}"
  # emits: {} (inline empty map) is guide-only; a bare "emits:" line opens a
  # multi-line block of real emitted keys and must not appear here.
  if grep -qE '^[[:space:]]*emits:[[:space:]]*$' <<<"$(printf '%s' "$blk" | nocomment /dev/stdin)"; then
    no "registry-population=$nm must not emit values"
  else ok "registry-population=$nm is guide-only"; fi
done

echo "== PREREQS: registry-prerequisites fragment wired + names the private source-GAR repo =="
PRQ="$PLUGIN_DIR/data/guide-sections/registry-prerequisites.md"
if [ -f "$PRQ" ]; then
  grep -q 'docker-runwhen-self-hosted' "$PRQ" && grep -qiE 'RunWhen.*(key|credential)' "$PRQ" && ok "registry-prerequisites names the private RunWhen source-GAR repo + key" || no "registry-prerequisites missing private source-GAR/key callout"
  grep -q '<REGISTRY_HOST>' "$PRQ" && ok "registry-prerequisites is tokenized on REGISTRY_HOST" || no "registry-prerequisites not tokenized"
else no "registry-prerequisites fragment missing"; fi
grep -q 'registry-prerequisites' "$CATALOG" && ok "registry-prerequisites referenced by catalog" || no "registry-prerequisites not referenced"

echo "== FLAT: flat-mirror option renders every image on the flat prefix =="
if grep -q 'id: flat-mirror' "$CATALOG"; then ok "flat-mirror option present"; else no "flat-mirror option missing"; fi
flat="$(option_block flat-mirror | grep -vE '^[[:space:]]*#')"
grep -qE 'registryOverride:\s*"<FLAT_PREFIX>"' <<<"$flat" && ok "flat-mirror sets registryOverride token" || no "flat-mirror missing registryOverride"
for sub in "redis" "neo4j" "vault" "qdrant" "seaweedfs" "metricstore"; do
  grep -q "$sub" <<<"$flat" && ok "flat-mirror emits $sub subchart key" || no "flat-mirror missing $sub subchart key"
done

echo ""
echo "airgap-registry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
