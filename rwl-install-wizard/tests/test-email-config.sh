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
d="$(render "$TMP/d.yaml")"
grep -q 'SKIP_EMAIL_VERIFICATION: "true"' <<<"$d" \
  && ok "email-disabled sets SKIP_EMAIL_VERIFICATION true" || no "email-disabled missing SKIP_EMAIL_VERIFICATION true"

echo "== email-smtp: EMAIL_* env + secret ref, verification enforced =="
emit_overlay email-smtp "$TMP/s.yaml" \
  SMTP_HOST=smtp.corp.example SMTP_PORT=587 SMTP_TLS_MODE=starttls \
  SMTP_EXISTING_SECRET=rw-smtp-creds EMAIL_FROM_ADDRESS=noreply@corp.example
r="$(render "$TMP/s.yaml")"
grep -q 'EMAIL_PROVIDER: "smtp"'                 <<<"$r" && ok "provider=smtp"            || no "provider not smtp"
grep -q 'EMAIL_SMTP_HOST: "smtp.corp.example"'   <<<"$r" && ok "EMAIL_SMTP_HOST set"      || no "EMAIL_SMTP_HOST missing"
grep -q 'EMAIL_SMTP_PORT: "587"'                 <<<"$r" && ok "EMAIL_SMTP_PORT set"      || no "EMAIL_SMTP_PORT missing"
grep -q 'EMAIL_SMTP_TLS_MODE: "starttls"'        <<<"$r" && ok "EMAIL_SMTP_TLS_MODE set"  || no "EMAIL_SMTP_TLS_MODE missing"
grep -q 'rw-smtp-creds'                          <<<"$r" && ok "SMTP secret ref wired"    || no "SMTP secret ref missing"
grep -q 'SKIP_EMAIL_VERIFICATION: "false"'       <<<"$r" && ok "verification enforced"    || no "skip flag not false"

rm -rf "$TMP"
echo ""; echo "email-config: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
