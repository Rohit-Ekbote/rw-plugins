#!/usr/bin/env ruby
# frozen_string_literal: true
#
# build-guide.rb — deterministic assembler for the RunWhen install kit's HTML docs.
#
#   ruby build-guide.rb --catalog <knob-catalog.yaml> --profile <profile.yaml> \
#                       --data <data/> --out <rwl-install-out/>
#
# Reads the operator's saved profile + the catalog + the vetted data/*.md fragments
# and writes four self-contained HTML files into --out:
#   index.html  USER-GUIDE.html  DEBUG-GUIDE.html  PREREQUISITES.html
#
# Design contract (see docs/superpowers/specs/2026-07-14-html-install-kit-design.md):
#   * DETERMINISTIC: same (catalog, profile, data, out-overlay-set) -> byte-identical
#     output. All page chrome (CSS/JS/shell/structure) is fixed here, so runs never
#     drift. This is the "predictable uniformity over multiple runs" guarantee.
#   * Fragment content comes ONLY from data/*.md — never authored here.
#   * Token substitution is limited to what the wizard actually knows (mechanical
#     answered params + CHART_COMPAT + REGISTRY_HOST_ONLY). Install-time and
#     illustrative fills (<RELEASE>, <CHART_REF>, <NAMESPACE>, <VAR>, lowercase
#     <release>/<domain>) are left VERBATIM — they are teaching placeholders, not
#     things the wizard resolves. Secret VALUES are never substituted.
#   * The three guides are ALWAYS written, each with a fallback body if its content
#     union is empty.
#   * Self-contained: no external asset references, so the kit opens offline.
#
# Pure Ruby (2.6+), no gems.

require 'yaml'
require 'set'

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
opts = {}
ARGV.each_slice(2) { |k, v| opts[k.sub(/^--/, '')] = v }
%w[catalog profile data out].each do |k|
  abort "build-guide: missing --#{k}" unless opts[k]
end
CATALOG = YAML.load_file(opts['catalog'])
PROFILE = YAML.load_file(opts['profile'])
DATA    = opts['data']
OUT     = opts['out']
abort "build-guide: data dir not found: #{DATA}" unless File.directory?(DATA)
Dir.mkdir(OUT) unless File.directory?(OUT)

GENERATED_AT = (PROFILE['generatedAt'] || '').to_s
CHART_COMPAT = (PROFILE['chartCompat'] || CATALOG['chartCompat'] || '').to_s

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def screaming(id)
  id.gsub(/([a-z0-9])([A-Z])/, '\1_\2').upcase
end

def esc(s)
  s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
end

def attr(s)
  esc(s).gsub('"', '&quot;')
end

# ---------------------------------------------------------------------------
# profile -> answered options (in catalog declaration order) + param values
# ---------------------------------------------------------------------------
# answers[axisId] is either {option:, <param>:...} (single) or a list of such
# (multi-select). Returns [{axis:, option:, params:{}}...] in catalog order.
def answered_options
  answers = PROFILE['answers'] || {}
  out = []
  (CATALOG['axes'] || []).each do |axis|
    a = answers[axis['id']]
    next if a.nil?
    entries = a.is_a?(Array) ? a : [a]
    entries.each do |e|
      next unless e.is_a?(Hash) && e['option']
      params = e.reject { |k, _| k == 'option' }
      out << { 'axis' => axis['id'], 'option' => e['option'], 'params' => params }
    end
  end
  out
end

ANSWERED = answered_options

# The option definitions selected, preserving catalog order — so guide/known-issue/
# prereq unions are ordered deterministically by catalog declaration order.
def selected_option_defs
  byid = {}
  (CATALOG['axes'] || []).each do |axis|
    (axis['options'] || []).each { |o| byid[[axis['id'], o['id']]] = o }
  end
  ANSWERED.map { |a| byid[[a['axis'], a['option']]] }.compact
end

SELECTED = selected_option_defs

# de-duplicated union of a list-valued key across selected options, catalog order
def union(key)
  seen = Set.new
  out = []
  SELECTED.each do |o|
    (o[key] || []).each { |id| out << id if seen.add?(id) }
  end
  out
end

# ---------------------------------------------------------------------------
# substitution map — only what the wizard genuinely knows
# ---------------------------------------------------------------------------
def substitution_map
  m = {}
  ANSWERED.each do |a|
    a['params'].each do |pid, val|
      next if val.nil?
      s = val.to_s
      next if s.strip.empty?
      m[screaming(pid)] = s
    end
  end
  m['CHART_COMPAT'] = CHART_COMPAT unless CHART_COMPAT.empty?
  # Flat-mirror answers only flatPrefix; the shared registry guide fragments are
  # tokenized on <REGISTRY_HOST>. Alias it so flat kits render the flat prefix
  # instead of leaking the literal token. (REGISTRY_HOST_ONLY then derives below.)
  m['REGISTRY_HOST'] ||= m['FLAT_PREFIX'] if m['FLAT_PREFIX']
  if m['REGISTRY_HOST']
    m['REGISTRY_HOST_ONLY'] = m['REGISTRY_HOST'].split('/').first
  end
  m
end

SUBST = substitution_map

# Replace only <UPPER_TOKEN>s present in the map. Everything else — literal
# operator-fills, lowercase illustrative tokens, secret placeholders — is left
# verbatim.
def substitute(text)
  text.gsub(/<([A-Z][A-Z0-9_]*)>/) { |m| SUBST.fetch($1, m) }
end

# ---------------------------------------------------------------------------
# overlays actually written by the SKILL -> composed helm -f lines
# ---------------------------------------------------------------------------
OVERLAY_ORDER = %w[values-registry.yaml values-storage.yaml values-cluster.yaml values-posture.yaml].freeze

def written_overlays
  OVERLAY_ORDER.select { |f| File.file?(File.join(OUT, f)) }
end

# Markers the fragments use to say "the wizard fills the generated overlays in
# here". Marker 1 sits on an already-indented line after `-f …/values.yaml \`, so
# the first composed line inherits that indent and the rest match it (2 spaces).
def compose_overlays(text)
  gen = written_overlays.map { |f| "-f #{f}" }
  text
    .gsub('<one -f line per generated overlay, in the order above>',
          gen.join(" \\\n  "))
    .gsub('<same -f overlays as above>', gen.join(' '))
end

# ---------------------------------------------------------------------------
# minimal, deterministic Markdown -> HTML (the bounded subset the fragments use:
# h1-h4, paragraphs, **bold**, `code`, [t](u), - / * lists, 1. lists, GFM tables,
# > blockquotes, ``` fenced code -> copy widget).
# ---------------------------------------------------------------------------
def inline(s)
  s = esc(s)
  # inline code first so ** inside code is not bolded
  s = s.gsub(/`([^`]+)`/) { "<code>#{$1}</code>" }
  s = s.gsub(/\*\*([^*]+)\*\*/) { "<strong>#{$1}</strong>" }
  s = s.gsub(/\[([^\]]+)\]\(([^)]+)\)/) { "<a href=\"#{attr($2)}\">#{$1}</a>" }
  s
end

def code_block(lang, body)
  cls = lang && !lang.empty? ? " data-lang=\"#{attr(lang)}\"" : ''
  <<~HTML.chomp
    <div class="cmd"#{cls}><button class="copy" type="button" aria-label="Copy to clipboard">Copy</button><pre><code>#{esc(body)}</code></pre></div>
  HTML
end

def table_html(rows)
  # rows: array of arrays of cells; row 0 is header, row 1 is the |---| separator
  head = rows[0]
  body = rows[2..] || []
  out = +"<table>\n<thead><tr>"
  head.each { |c| out << "<th>#{inline(c.strip)}</th>" }
  out << "</tr></thead>\n<tbody>\n"
  body.each do |r|
    out << '<tr>'
    r.each { |c| out << "<td>#{inline(c.strip)}</td>" }
    out << "</tr>\n"
  end
  out << "</tbody>\n</table>"
  out
end

def split_row(line)
  line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|')
end

def md_to_html(md)
  lines = md.split("\n", -1)
  out = []
  i = 0
  para = []
  flush_para = lambda do
    unless para.empty?
      out << "<p>#{inline(para.join(' ').strip)}</p>"
      para = []
    end
  end

  while i < lines.size
    line = lines[i]

    # fenced code block
    if line =~ /\A```(\w*)\s*\z/
      flush_para.call
      lang = $1
      body = []
      i += 1
      while i < lines.size && lines[i] !~ /\A```\s*\z/
        body << lines[i]
        i += 1
      end
      out << code_block(lang, body.join("\n"))
      i += 1
      next
    end

    # heading
    if line =~ /\A(#+)\s+(.*)\z/
      level = [$1.length, 6].min
      flush_para.call
      out << "<h#{level}>#{inline($2.strip)}</h#{level}>"
      i += 1
      next
    end

    # blockquote (consecutive > lines)
    if line =~ /\A>\s?(.*)\z/
      flush_para.call
      buf = []
      while i < lines.size && lines[i] =~ /\A>\s?(.*)\z/
        buf << $1
        i += 1
      end
      out << "<blockquote>#{md_to_html(buf.join("\n"))}</blockquote>"
      next
    end

    # GFM table (header line, separator line of ---, then rows)
    if line =~ /\A\|.*\|\s*\z/ && i + 1 < lines.size && lines[i + 1] =~ /\A\|[\s:\-|]+\|\s*\z/
      flush_para.call
      rows = []
      while i < lines.size && lines[i] =~ /\A\|.*\|\s*\z/
        rows << split_row(lines[i])
        i += 1
      end
      out << table_html(rows)
      next
    end

    # A continuation line wraps the current list item: indented, non-blank, and not
    # itself the start of another block (new bullet / ordered item / fenced code).
    # Such lines are joined into the item so multi-line bullets render as one <li>
    # instead of leaking their tail as a stray <p>.
    is_continuation = lambda do |ln|
      ln =~ /\A\s+\S/ && ln !~ /\A\s*[-*]\s+/ && ln !~ /\A\s*\d+\.\s+/ && ln !~ /\A\s*```/
    end
    collect_item = lambda do |first|
      item = first
      while i < lines.size && is_continuation.call(lines[i])
        item = "#{item.rstrip} #{lines[i].strip}"
        i += 1
      end
      item
    end

    # unordered list
    if line =~ /\A[-*]\s+(.*)\z/
      flush_para.call
      items = []
      while i < lines.size && lines[i] =~ /\A[-*]\s+(.*)\z/
        first = $1
        i += 1
        items << collect_item.call(first)
      end
      out << "<ul>\n" + items.map { |it| "<li>#{inline(it.strip)}</li>" }.join("\n") + "\n</ul>"
      next
    end

    # ordered list
    if line =~ /\A\d+\.\s+(.*)\z/
      flush_para.call
      items = []
      while i < lines.size && lines[i] =~ /\A\d+\.\s+(.*)\z/
        first = $1
        i += 1
        items << collect_item.call(first)
      end
      out << "<ol>\n" + items.map { |it| "<li>#{inline(it.strip)}</li>" }.join("\n") + "\n</ol>"
      next
    end

    # blank line ends a paragraph
    if line.strip.empty?
      flush_para.call
      i += 1
      next
    end

    para << line
    i += 1
  end
  flush_para.call
  out.join("\n")
end

# Load + substitute + compose a fragment, then convert to HTML.
def fragment_html(subdir, id)
  path = File.join(DATA, subdir, "#{id}.md")
  return nil unless File.file?(path)
  raw = File.read(path)
  md_to_html(compose_overlays(substitute(raw)))
end

# ---------------------------------------------------------------------------
# boilerplate — the uniformity guarantee. Inline CSS + copy JS, no external refs.
# ---------------------------------------------------------------------------
CSS = <<~CSS
  :root{color-scheme:light dark}
  *{box-sizing:border-box}
  body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1a1f26;background:#fff}
  .wrap{max-width:72ch;margin:0 auto;padding:2.5rem 1.25rem 6rem}
  h1{font-size:1.7rem;line-height:1.25;margin:.2em 0 .6em}
  h2{font-size:1.35rem;margin:2em 0 .5em;padding-bottom:.25em;border-bottom:1px solid #e6e8eb}
  h3{font-size:1.12rem;margin:1.7em 0 .4em}
  h4{font-size:1rem;margin:1.4em 0 .3em;color:#3a4250}
  p,li{margin:.5em 0}
  ul,ol{padding-left:1.4em}
  a{color:#0b6bcb}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em;background:#f0f2f4;border-radius:4px;padding:.1em .35em}
  table{border-collapse:collapse;width:100%;margin:1em 0;font-size:.94em}
  th,td{border:1px solid #e6e8eb;padding:.45em .6em;text-align:left;vertical-align:top}
  th{background:#f6f8fa}
  blockquote{margin:1em 0;padding:.5em 1em;border-left:3px solid #d5b53c;background:#fbf7e8;border-radius:0 6px 6px 0}
  blockquote p:first-child{margin-top:0}blockquote p:last-child{margin-bottom:0}
  .meta{color:#6b7580;font-size:.85rem;margin:0 0 2rem}
  .nav{display:flex;flex-wrap:wrap;gap:.5rem;margin:0 0 2rem}
  .nav a{display:inline-block;padding:.35em .8em;border:1px solid #d7dbe0;border-radius:999px;text-decoration:none;color:#0b6bcb}
  .cmd{position:relative;margin:1em 0}
  .cmd pre{margin:0;overflow:auto;background:#0f141a;color:#e6edf3;border-radius:8px;padding:1em 1em;font-size:.88em;line-height:1.5}
  .cmd pre code{background:none;padding:0;color:inherit;font-size:inherit}
  .cmd .copy{position:absolute;top:.5em;right:.5em;font:inherit;font-size:.75rem;padding:.25em .7em;border:1px solid #33404d;border-radius:6px;background:#1c2530;color:#c7d1dc;cursor:pointer}
  .cmd .copy:hover{background:#26313e}
  .cmd .copy.copied{background:#1f7a3d;border-color:#1f7a3d;color:#fff}
  .files{list-style:none;padding:0}
  .files li{padding:.3em 0;border-bottom:1px solid #eef0f2}
  .files code{background:none;padding:0}
  @media(prefers-color-scheme:dark){
    body{background:#0f141a;color:#d7dee6}
    h2{border-color:#232c36}h4{color:#9aa6b2}
    code{background:#1b232c}
    th,td{border-color:#232c36}th{background:#161d25}
    blockquote{background:#1c1a12;border-left-color:#b9992f}
    a,.nav a{color:#4aa3ff}
    .meta{color:#8a95a1}
    .nav a{border-color:#2a333d}
    .files li{border-color:#1c242d}
  }
CSS

COPY_JS = <<~JS
  document.addEventListener('click',function(e){
    var b=e.target.closest('.copy');if(!b)return;
    var pre=b.parentElement.querySelector('pre');
    var t=pre?pre.innerText:'';
    var done=function(){b.classList.add('copied');var o=b.textContent;b.textContent='Copied';setTimeout(function(){b.classList.remove('copied');b.textContent=o;},1400);};
    if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,function(){});}
    else{var ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);ta.select();try{document.execCommand('copy');done();}catch(_){}document.body.removeChild(ta);}
  });
JS

def page(title, body)
  meta = []
  meta << "Chart compatibility: #{esc(CHART_COMPAT)}" unless CHART_COMPAT.empty?
  meta << "Generated: #{esc(GENERATED_AT)}" unless GENERATED_AT.empty?
  metahtml = meta.empty? ? '' : "<p class=\"meta\">#{meta.join(' · ')}</p>"
  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(title)}</title>
    <style>#{CSS}</style>
    </head>
    <body>
    <div class="wrap">
    <nav class="nav">
    <a href="index.html">Kit home</a>
    <a href="PREREQUISITES.html">Prerequisites</a>
    <a href="USER-GUIDE.html">Install guide</a>
    <a href="DEBUG-GUIDE.html">Debug guide</a>
    </nav>
    <h1>#{esc(title)}</h1>
    #{metahtml}
    #{body}
    </div>
    <script>#{COPY_JS}</script>
    </body>
    </html>
  HTML
end

def write(name, title, body)
  File.write(File.join(OUT, name), page(title, body))
end

# ---------------------------------------------------------------------------
# assemble the four documents
# ---------------------------------------------------------------------------

# USER-GUIDE: union of guide_sections (catalog order). Fallback when empty.
guide_ids = union('guide_sections')
guide_body = guide_ids.map { |id| fragment_html('guide-sections', id) }.compact
user_body =
  if guide_body.empty?
    '<p>No guided install sections apply to the selected options. Layer the ' \
    'generated <code>values-*.yaml</code> overlays onto the chart in apply ' \
    'order and consult the chart\'s own <code>values.yaml</code>.</p>'
  else
    guide_body.join("\n")
  end
write('USER-GUIDE.html', 'RunWhen platform — install guide', user_body)

# DEBUG-GUIDE: union of known_issues. Fallback when empty.
issue_ids = union('known_issues')
issue_body = issue_ids.map { |id| fragment_html('known-issues', id) }.compact
debug_body =
  if issue_body.empty?
    '<p>No known issues are associated with the selected options for this chart ' \
    'range. If an install misbehaves, re-run the pre-flight render gate in ' \
    '<a href="PREREQUISITES.html">Prerequisites</a> and compare the rendered ' \
    'manifests against your overlays.</p>'
  else
    issue_body.join("\n")
  end
write('DEBUG-GUIDE.html', 'RunWhen platform — debug guide', debug_body)

# PREREQUISITES: union of prereqs (always) + a pre-flight render gate.
prereq_ids = union('prereqs')
prereq_frags = prereq_ids.map { |id| fragment_html('prerequisites', id) }.compact
render_cmd = +"helm template <RELEASE> <CHART_REF> \\\n"
render_cmd << "  -f runwhen-platform/values.yaml"
written_overlays.each { |f| render_cmd << " \\\n  -f #{f}" }
render_cmd << " \\\n  | kubectl apply --dry-run=client -f -"
gate_html = "<h2>Pre-flight render gate</h2>\n" \
            "<p>Run this yourself before installing — it never contacts a cluster " \
            "and validates that every generated overlay layers cleanly. The wizard " \
            "does not run it for you.</p>\n" + code_block('bash', render_cmd)
prereq_body =
  (prereq_frags.empty? ?
    '<p>No option-specific cluster prerequisites apply to the selected options.</p>' :
    prereq_frags.join("\n")) + "\n" + gate_html
write('PREREQUISITES.html', 'RunWhen platform — prerequisites', prereq_body)

# index: landing page — links + the overlays this run generated.
overlays = written_overlays
files_html =
  if overlays.empty?
    '<p>No values overlays were generated for the selected options.</p>'
  else
    "<ul class=\"files\">\n" +
      overlays.map { |f| "<li><code>#{esc(f)}</code></li>" }.join("\n") +
      "\n</ul>"
  end
index_body = <<~HTML
  <p>This kit was generated from your saved install profile. Open the guides
  below; each command block has a <strong>Copy</strong> button. Nothing here
  contacts a cluster.</p>
  <h2>Generated values overlays</h2>
  #{files_html}
  <h2>Guides</h2>
  <ul class="files">
  <li><a href="PREREQUISITES.html">Prerequisites</a> — cluster requirements + pre-flight render gate</li>
  <li><a href="USER-GUIDE.html">Install guide</a> — step-by-step, with the composed helm command</li>
  <li><a href="DEBUG-GUIDE.html">Debug guide</a> — known issues for your selected shape</li>
  </ul>
HTML
write('index.html', 'RunWhen platform — install kit', index_body)

puts "build-guide: wrote index.html, USER-GUIDE.html, DEBUG-GUIDE.html, PREREQUISITES.html to #{OUT}"
