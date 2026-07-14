#!/usr/bin/env ruby
# extract-capabilities.rb <templates-dir>
# Emit the chart's *capability surface* — the decision-worthy feature switches an
# operator can flip — as a sorted, de-duplicated set, one per line:
#
#   disc:<valuesPath>=<literal>   a feature discriminator: a `.Values.<path>` that a
#                                 template conditional (eq/ne) compares against a
#                                 string literal (a mode/type/kind switch, plus the
#                                 `| default "x"` branch value when present).
#   dir:<name>                    a templates/<name>/ subsystem (a feature area).
#
# check_coverage diffs this against capabilities.baseline; anything NEW is a chart
# capability the catalog may not model yet. This catches a class the render check is
# blind to: a brand-new feature (e.g. Gateway API's ingress.type=gateway + a new
# templates/gateway/ dir) that the catalog does not yet expose. `helm template` of
# the EXISTING options stays green, so only a coverage diff surfaces it.
#
# Deterministic, pure Ruby (2.6+), no gems. Known limitation (accepted, mirrors
# extract-fails.rb): matching is per-line and only covers the `eq/ne (.Values.X …)
# "LIT"` form the chart actually uses — a discriminator built from a variable, a
# reversed `eq "LIT" .Values.X`, or a multi-line conditional is not captured.

require 'find'

dir = ARGV[0]
abort "usage: extract-capabilities.rb <templates-dir>" unless dir && File.directory?(dir)

caps = {}   # entry -> true (set)

# --- feature discriminators -------------------------------------------------
# eq (.Values.ingress.type | default "ingress") "gateway"
#   -> path=ingress.type, default="ingress", compared="gateway"
#      => disc:ingress.type=ingress  AND  disc:ingress.type=gateway
# eq .Values.secrets.method "csi"  -> disc:secrets.method=csi
DISC = /\b(?:eq|ne)\s+\(?\s*\.Values\.([A-Za-z0-9_.]+)(?:\s*\|\s*default\s+"([^"]*)")?\s*\)?\s*"([^"]*)"/

Find.find(dir) do |path|
  next unless File.file?(path) && path =~ /\.(ya?ml|tpl)\z/
  File.foreach(path, encoding: 'UTF-8') do |raw|
    raw.scrub.scan(DISC) do |m|
      p = m[0]
      [m[1], m[2]].each { |lit| caps["disc:#{p}=#{lit}"] = true if lit && !lit.empty? }
    end
  end
end

# --- template subsystems ----------------------------------------------------
Dir.glob(File.join(dir, '*')).each do |p|
  caps["dir:#{File.basename(p)}"] = true if File.directory?(p)
end

puts caps.keys.sort
