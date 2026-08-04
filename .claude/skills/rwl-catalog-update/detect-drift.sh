#!/usr/bin/env bash
# detect-drift.sh --chart <dir> [--catalog <f>] [--out <dir>]
# Deterministic drift detector. Writes <out>/findings.tsv; never edits sources.
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"
CATALOG="$REPO/rwl-install-wizard/data/knob-catalog.yaml"
CHART=""; OUT="./.rwl-catalog-drift"

while [ $# -gt 0 ]; do
  case "$1" in
    --chart)   CHART="$2"; shift 2 ;;
    --catalog) CATALOG="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CHART" ] && [ -f "$CHART/Chart.yaml" ] || { echo "usage: --chart <dir with Chart.yaml>" >&2; exit 2; }
mkdir -p "$OUT"; FINDINGS="$OUT/findings.tsv"; : > "$FINDINGS"

# emit_finding <bucket:auto|decide> <kind> <option> <detail> <evidence> <current> <chart>
emit_finding() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$FINDINGS"
}

check_chartcompat() {
  local ver compat
  ver="$(awk '/^version:/{print $2; exit}' "$CHART/Chart.yaml")"
  compat="$(awk -F'"' '/^chartCompat:/{print $2; exit}' "$CATALOG")"
  local upper lower vmm
  upper="$(printf '%s' "$compat" | sed -nE 's/.*<([0-9]+\.[0-9]+).*/\1/p')"
  lower="$(printf '%s' "$compat" | sed -nE 's/.*>=([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')"
  vmm="$(printf '%s' "$ver" | sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p')"
  local outside=""
  # At/above the exclusive upper bound (0.3.x is outside `<0.3`).
  if [ -n "$upper" ] && [ -n "$vmm" ] && [ "$(printf '%s\n%s\n' "$vmm" "$upper" | sort -V | head -1)" = "$upper" ]; then
    outside="above"
  fi
  # Below the inclusive lower bound.
  if [ -n "$lower" ] && [ "$(printf '%s\n%s\n' "$ver" "$lower" | sort -V | head -1)" = "$ver" ] && [ "$ver" != "$lower" ]; then
    outside="below"
  fi
  if [ -n "$outside" ]; then
    emit_finding decide chartCompat "" "chart $ver is outside catalog range $compat ($outside bound)" "$CHART/Chart.yaml" "$compat" "$ver"
  else
    emit_finding auto chartCompat "" "chart $ver within catalog range $compat" "$CHART/Chart.yaml" "$compat" "$ver"
  fi
}

check_validators() {
  local helpers="$CHART/templates/_helpers.tpl"; [ -f "$helpers" ] || return 0
  local baseline="$SKILL_DIR/validators.baseline"
  grep -oE 'define "runwhen\.[a-zA-Z.]*validate"' "$helpers" \
    | sed -E 's/define "(.*)"/\1/' | sort -u > "$OUT/validators.chart"
  # names in chart but not in baseline = newly added
  comm -13 <(sort -u "$baseline") "$OUT/validators.chart" | while IFS= read -r v; do
    [ -n "$v" ] || continue
    emit_finding decide validator "" "new fail-fast validator '$v' — may require a new question/param" "$helpers" "" "$v"
  done
}

check_fails() {
  local tdir="$CHART/templates"; [ -d "$tdir" ] || return 0
  local baseline="$SKILL_DIR/fails.baseline"
  ruby "$SKILL_DIR/extract-fails.rb" "$tdir" > "$OUT/fails.chart.full"
  cut -f1 "$OUT/fails.chart.full" | sort -u > "$OUT/fails.chart"
  # signatures present in the chart but not the baseline = newly added invariants
  comm -13 <(sort -u "$baseline" 2>/dev/null) "$OUT/fails.chart" | while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    local file; file="$(awk -F'\t' -v s="$sig" '$1==s{print $2; exit}' "$OUT/fails.chart.full")"
    emit_finding decide fail "" "new inline chart fail: ${sig:0:140}" "$tdir/$file" "" ""
  done
}

# check_coverage — the class the render check is blind to: a NEW chart capability
# the catalog does not model yet. `helm template` of the EXISTING options stays
# green when the chart grows a whole new feature (e.g. Gateway API added
# `ingress.type=gateway` + a `templates/gateway/` dir in 0.2.58), so no render/
# validator/fail finding fires. Extract the chart's capability surface (feature
# discriminators + template subsystems) and diff it against capabilities.baseline
# — a "seen as of chart X" snapshot, exactly like validators.baseline. Anything new
# is a coverage gap: model it in the catalog, or (if intentionally not modeled)
# regenerate/extend the baseline to acknowledge it.
check_coverage() {
  local tdir="$CHART/templates"; [ -d "$tdir" ] || return 0
  local baseline="$SKILL_DIR/capabilities.baseline"
  ruby "$SKILL_DIR/extract-capabilities.rb" "$tdir" | sort -u > "$OUT/capabilities.chart"
  comm -13 <(sort -u "$baseline" 2>/dev/null) "$OUT/capabilities.chart" | while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    emit_finding decide coverageGap "" "unmodeled chart capability '$cap' — new since capabilities.baseline; model it in the catalog or add it to the baseline" "$tdir" "" "$cap"
  done
}

# Read catalog pinnedTags via ruby (neo4j/vault/bciBaseHelmTest -> version string).
catalog_pinned() {
  ruby -ryaml -e '
    c=YAML.load_file(ARGV[0])
    c["axes"].each{|a| (a["options"]||[]).each{|o|
      n=((o["emits"]||{})["x-airgap-pinned-tags-notice"]||{})["pinnedTags"]
      next unless n
      n.each{|k,v| puts "#{k}\t#{v}"}
    }}' "$CATALOG" | sort -u
}

# Default bundled render — ground truth for the resolved subchart image tags. The
# chart's values-example-*.yaml can LAG the actual subchart by many releases (it
# still showed neo4j:5.26.0 long after the chart moved to 5.26.28-ubi10), so it is
# documentation, not a source of truth. When a render is available it decides BOTH
# whether a pin has drifted and what the pin should become; the example is only a
# fallback for when there is no render (no helm, or a non-renderable fixture).
render_default() {
  command -v helm >/dev/null 2>&1 || return 1
  [ -f "$CHART/values.yaml" ] || return 1
  helm template rw "$CHART" \
    --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
    --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities \
    --set llmGateway.deploy=false 2>/dev/null
}

check_tags() {
  local ex="$CHART/values-example-airgap-jcr.yaml"; [ -f "$ex" ] || return 0
  # chart tags for the three pinned images, parsed from the example.
  local c_neo4j c_vault c_bci
  c_neo4j="$(grep -oE 'library/neo4j:[^"[:space:]]+' "$ex" | head -1 | sed 's#.*:##')"
  c_vault="$(awk '/hashicorp\/vault/{f=1} f&&/tag:/{gsub(/[",]/,"",$2);print $2;exit}' "$ex")"
  c_bci="$(grep -v '^[[:space:]]*#' "$CHART/values.yaml" 2>/dev/null | grep -oE 'bci/bci-base:[^"[:space:]]+' | head -1 | sed 's#.*:##')"
  local rf; rf="$(mktemp)"; render_default > "$rf" 2>/dev/null || : > "$rf"
  catalog_pinned | while IFS="$(printf '\t')" read -r name ver; do
    local ex_ver="" pat=""
    case "$name" in
      neo4j)           ex_ver="$c_neo4j"; pat='(library/)?neo4j' ;;
      vault)           ex_ver="$c_vault"; pat='hashicorp/vault' ;;
      bciBaseHelmTest) ex_ver="$c_bci";   pat='bci/bci-base' ;;
    esac

    # Every tag this image renders under. An image can legitimately render more
    # than one (vault ships 2.0.3 for the subchart server and 1.21.2 for the
    # chart's own vault-binary jobs), so the question is set MEMBERSHIP: "is the
    # pinned tag one of the tags the chart actually resolves?"
    local rendered=""
    [ -s "$rf" ] && rendered="$(grep -E '(image|customImage):' "$rf" \
      | grep -oE "${pat}:[A-Za-z0-9._-]+" | sed 's/.*://' | sort -u)"

    if [ -n "$rendered" ]; then
      # EXACT, whole-line, fixed-string. Deliberately NOT suffix- or prefix-
      # tolerant: `5.26.28` and `5.26.28-ubi10` are different images (Debian vs
      # UBI base, different CVE surface), so treating the suffix as noise would
      # have SUPPRESSED the real finding when the chart moved to the UBI build in
      # 0.2.70 — the catalog would have kept mirroring the Debian image forever.
      # -F because a pinned tag is a literal: unescaped `.` in `5.26.28` would
      # otherwise match any character.
      printf '%s\n' "$rendered" | grep -qxF "$ver" && continue
      # Drifted. Report what the chart RENDERS as the target — never the example,
      # which is what previously proposed reverting 5.26.28 to the stale 5.26.0.
      # If several tags render and none is the pin, list them all rather than
      # guessing; the maintainer picks.
      local target; target="$(printf '%s' "$rendered" | tr '\n' ',' | sed 's/,$//')"
      emit_finding auto tag "$name" "pinned $name tag $ver != chart render $target" \
        "$CHART/values.yaml" "$ver" "$target"
      continue
    fi

    # No render for this image — weaker evidence. The example may be stale, so
    # say so in the finding instead of presenting it as a safe mechanical fix.
    [ -n "$ex_ver" ] || continue
    [ "$ex_ver" = "$ver" ] && continue
    emit_finding auto tag "$name" \
      "pinned $name tag $ver != chart example $ex_ver (no render — the example can lag; verify against the chart before applying)" \
      "$ex" "$ver" "$ex_ver"
  done
  rm -f "$rf"
}

PUBLIC_HOSTS='us-docker\.pkg\.dev|ghcr\.io|quay\.io|registry-1\.docker\.io|docker\.io|registry\.k8s\.io|registry\.suse\.com'

list_options() {
  ruby -ryaml -e '
    YAML.load_file(ARGV[0])["axes"].each{|a| (a["options"]||[]).each{|o|
      puts o["id"] if o["overlay"] && o["emits"] && o["emits"]!={} }}' "$CATALOG"
}

axis_of() {
  ruby -ryaml -e '
    id=ARGV[1]
    YAML.load_file(ARGV[0])["axes"].each{|a| (a["options"]||[]).each{|o|
      if o["id"]==id then puts a["id"]; exit end }}' "$CATALOG" "$1"
}

# Axes whose options dependsOn a mirror layout (registry-auth / registry-population):
# in the real interview they are only ever chosen alongside a layout, and they omit
# layout-owned keys (e.g. neo4j.disableLookups). Rendering them alone is an
# isolation artifact (a MISSED-10-shaped false positive), so the render check layers
# them ON TOP of this representative layout. The layout itself is still rendered
# alone elsewhere in the loop, so a real MISSED-10 regression on the layout (dropping
# disableLookups) is still caught there.
LAYOUT_PARTNER="mirrored-per-upstream"
depends_on_layout() { case "$(axis_of "$1")" in registry-auth|registry-population) return 0 ;; *) return 1 ;; esac }

check_render() {
  if ! command -v helm >/dev/null 2>&1 || [ ! -f "$CHART/values.yaml" ]; then
    emit_finding auto renderSkipped "" "helm or chart values.yaml unavailable — render checks skipped" "$CHART" "" ""
    return 0
  fi
  local opt tmp ov llm_off
  for opt in $(list_options); do
    tmp="$(mktemp -d)"
    # A dependent-axis option is layered on top of a representative layout so it
    # renders as it would in real use (see LAYOUT_PARTNER note above).
    if depends_on_layout "$opt"; then
      ruby "$SKILL_DIR/gen-overlays.rb" "$CATALOG" "$tmp" "$LAYOUT_PARTNER" >/dev/null
    fi
    ov="$(ruby "$SKILL_DIR/gen-overlays.rb" "$CATALOG" "$tmp" "$opt" --answers)"
    [ -n "$ov" ] || { rm -rf "$tmp"; continue; }
    # The chart fail-fasts when llmGateway.deploy=true and models[] is empty — the
    # DEFAULT — so options that don't configure the gateway can't render in isolation.
    # Disable the gateway for those. Do NOT disable it for an overlay that configures
    # llmGateway itself (e.g. internal-openai): --set would override the overlay and
    # blind this check to llmGateway.*/llmBootstrap drift, the exact surface it must cover.
    llm_off="--set llmGateway.deploy=false"
    grep -q '^llmGateway:' "$tmp/$ov" && llm_off=""
    # Render the overlay VERBATIM (plus only the llm_off isolation-enabler above,
    # which the plugin cannot express per-option). Deliberately NO neo4j/qdrant
    # disableLookups --set: that crutch would hide a MISSED-10-class drift (an
    # overlay wiring pull secrets without disableLookups) — the exact failure this
    # render check exists to catch. The plugin emits disableLookups itself now.
    if helm template rw "$CHART" -f "$CHART/values.yaml" -f "$tmp/$ov" $llm_off \
         > "$tmp/render.yaml" 2> "$tmp/err"; then
      # The public-ref invariant applies ONLY to the registry overlay — it is the
      # one that mirrors images. Every other overlay legitimately inherits the
      # chart's public default images for services it doesn't touch, so checking
      # those would emit noise, not drift.
      if [ "$ov" = "values-registry.yaml" ] && grep -Eo '(image|customImage): *"?[^" }]+' "$tmp/render.yaml" \
           | grep -vE 'git_url|github\.com' | grep -Eq "$PUBLIC_HOSTS"; then
        emit_finding decide publicRef "$opt" "registry option renders a public image ref against this chart" "$CHART" "" ""
      fi
      # value-at-consumer: does any declared consumer resolve to the wrong value?
      if [ -f "$tmp/answers.yaml" ] && \
         ! ruby "$REPO/rwl-install-wizard/lib/check-consumers.rb" "$CATALOG" "$tmp/answers.yaml" "$tmp/render.yaml" --present-only >/dev/null 2>&1; then
        emit_finding decide consumerMismatch "$opt" "an operator input does not reach its declared consumer" "$CHART" "" ""
      fi
    else
      emit_finding decide render "$opt" "option fails to render: $(head -1 "$tmp/err" | cut -c1-160)" "$CHART" "" ""
    fi
    rm -rf "$tmp"
  done
}

# check_manifest — the class BOTH existing image checks miss. `check_tags` covers
# only the three hard-pinned tags (3 of ~21 images), and the publicRef guard only
# asks whether a ref ESCAPED the mirror — never whether it landed on a path the
# operator was actually told to create. Chart 0.2.73 moved Spilo from
# ghcr.io/zalando to ghcr.io/runwhen-contrib; the per-upstream overlay kept
# rendering <HOST>/docker-ghcr/zalando/spilo-17, which is on the mirror (both
# checks green) and unpullable in a real air-gap cluster.
#
# The per-upstream layout is PATH-PRESERVING, so a manifest entry
#   <upstream-registry>/<source-path>:<tag>
# must appear in the render as
#   <REGISTRY_HOST>/<remote>/<source-path>:<tag>
# i.e. "<source-path>:<tag> is a /-delimited suffix of the rendered ref". Deriving
# the invariant this way needs no upstream->remote table: it stays correct when a
# new remote is added. Only the per-upstream manifest is checked — the FLAT layout
# drops source paths by design, so the suffix rule does not apply to it.
MANIFEST_MD="$REPO/rwl-install-wizard/data/guide-sections/airgap-image-manifest.md"

check_manifest() {
  command -v helm >/dev/null 2>&1 || return 0
  [ -f "$CHART/values.yaml" ] || return 0
  [ -f "$MANIFEST_MD" ] || return 0
  local tmp ov; tmp="$(mktemp -d)"
  ov="$(ruby "$SKILL_DIR/gen-overlays.rb" "$CATALOG" "$tmp" "$LAYOUT_PARTNER")"
  [ -n "$ov" ] || { rm -rf "$tmp"; return 0; }
  # Gateway ON with a dummy model: litellm IS in the manifest, and the chart
  # fail-fasts on an empty model_list — rendering it off would report the gateway
  # image as a phantom orphan.
  if ! helm template rw "$CHART" -f "$CHART/values.yaml" -f "$tmp/$ov" \
        --set objectStorage.kind=seaweedfs --set seaweedfs.deploy=true \
        --set seaweedfs.s3.existingConfigSecret=rw-seaweedfs-identities \
        --set llmGateway.deploy=true --set llmGateway.database.enabled=true \
        --set 'llmGateway.models[0].model_name=m' \
        --set 'llmGateway.models[0].litellm_params.model=openai/m' \
        --set 'llmGateway.models[0].litellm_params.api_key=x' \
        > "$tmp/render.yaml" 2>"$tmp/err"; then
    rm -rf "$tmp"; return 0
  fi
  # Manifest source-paths: keep ref lines only, drop trailing comments, strip the
  # upstream registry (everything up to the first `/`).
  grep -E '^[a-z0-9.-]+\.[a-z]+/' "$MANIFEST_MD" \
    | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//; s#^[^/]+/##' \
    | sort -u > "$tmp/manifest.txt"
  grep -Eo '(image|customImage): *"?[^" }]+' "$tmp/render.yaml" \
    | sed -E 's/^[^:]*: *"?//' | sort -u > "$tmp/render.txt"
  : > "$tmp/hit"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    local m=""
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      case "$ref" in */"$src") m="$src"; break ;; esac
    done < "$tmp/manifest.txt"
    if [ -n "$m" ]; then
      printf '%s\n' "$m" >> "$tmp/hit"
    else
      emit_finding decide mirrorPath "" \
        "rendered image sits on no path the air-gap manifest tells operators to mirror: $ref" \
        "$MANIFEST_MD" "$ref" ""
    fi
  done < "$tmp/render.txt"
  comm -23 "$tmp/manifest.txt" <(sort -u "$tmp/hit") | while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    emit_finding decide manifestOrphan "" \
      "air-gap manifest lists an image the chart no longer renders: $orphan" \
      "$MANIFEST_MD" "$orphan" ""
  done
  rm -rf "$tmp"
}

check_chartcompat
check_validators
check_fails
check_coverage
check_tags
check_manifest
check_render
ruby "$SKILL_DIR/assemble-report.rb" "$FINDINGS" "$OUT"
A="$(awk -F'\t' '$1=="auto"' "$FINDINGS" | wc -l | tr -d ' ')"
D="$(awk -F'\t' '$1=="decide"' "$FINDINGS" | wc -l | tr -d ' ')"
echo "drift: $A auto-fixable, $D need decision -> $OUT/drift-report.md"
