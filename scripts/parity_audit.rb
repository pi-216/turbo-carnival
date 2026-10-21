#!/usr/bin/env ruby
# frozen_string_literal: true

#
# scripts/parity_audit.rb — PRD 0006 W1.4 parity audit (ticket #90).
#
# Emits one line per template rail R1..R9:
#
#   R<n>  CONFORM    <evidence the mechanism probe found>
#   R<n>  GAP        <what is missing or drifted — and why it is not ratified>
#   R<n>  DEVIATION  <the ratified deviation, with its ruling and ticket>
#
# Exit codes:
#   0 — no rail in GAP (CONFORMs + approved deviations only)
#   1 — one or more rails in GAP
#   2 — no disposition: a rail produced no verdict at all (fail-closed; a rail
#       must never be silently missing)
#
# Pinned references (not the tip of a moving branch):
#
#   GENERATOR PIN  be6068822072dc57aede7401b29817511bb97288
#     pi-216/rails-venture-template at audit-creation. Every artifact the
#     template emits lives in a heredoc of template.rb at this commit; the
#     sha256 values below were derived from those heredocs (dedented).
#
#   FILES PIN      8dc4586b941a2b94c08f69b70d91d0a53e0c51a348
#     the test-signal merge (template repo PR #9), where bin/rspec,
#     lib/rspec/agent_formatter.rb and bin/test-agent-signal exist as tree
#     files — the same pin AGENTS.md's own parity check uses. Re-derive with:
#       git -C <template clone> show 8dc4586b941a:bin/rspec | sha256sum
#
#   config/initializers/sentry.rb is the template content plus the four-line
#   port-provenance header recorded by ticket #77; both shas are below.
#
# The probes assert the mechanism, not the artifact:
#   R2 reads the actual layout meta/importmap wiring, not a "looks Turbo" grep
#       over all views;
#   R3 checks the loaded ancestor chain (ApplicationCommand < GLCommand::Callable)
#       and that no command file bypasses the rail;
#   R4 boots the app and probes the live Zeitwerk autoload paths, the live
#       ActionView path set, and real constant resolution across packs;
#   R6 parses the actual gate membership out of bin/verify and the CI workflow;
#   R7 checks the DSN wiring into encrypted credentials and the telemetry
#       emission, and that no plaintext DSN is committed.
#
# Debug hook: PARITY_AUDIT_SKIP="R9,R3" (comma list) suppresses the listed
# rails — used by the spec to exercise the no-disposition exit (2).

require "digest"
require "find"

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)

GENERATOR_PIN = "be6068822072dc57aede7401b29817511bb97288"
FILES_PIN = "8dc4586b941a2b94c08f69b70d91d0a53e0c51a348"

# Ported artifacts that must track the pins byte-for-byte.
#   [path, sha256 (repo file as ported), rail, reference]
# "FILES"  = tree file at the files pin (re-derivable with git show).
# "HDOC"   = template.rb heredoc at the generator pin.
ARTIFACTS = [
  [ "bin/rspec", "a050cd0cf37276b6478d4ab09fcbccafb6f20de3eb1fe64f2af1660b25128fe2", :R6, "FILES" ],
  [ "lib/rspec/agent_formatter.rb", "db1c30b9bd3a78934720d207145b16a4133ab0f2b51353130b2eaa8ba7583389", :R6, "FILES" ],
  [ "bin/test-agent-signal", "84a09890151cd77ffb0ac774092d4875dc292e87811b4655fad2a2df6f05f2c3", :R6, "FILES" ],
  [ ".erb_lint.yml", "8ef8be869a544943d92250896322061d854220e760497c9b49fc67af6bd1cd74", :R6, "HDOC" ],
  [ "app/commands/application_command.rb", "e650a142ee4c7aca5023fbfaeadd72202fa66f508717f5b21276d91fb35ab835", :R3, "HDOC" ],
  [ ".gherkin_lint.yml", "fe2849a8dedad5cc31b1a261f13049f5e9ffe5e11278413e544c5525038d0726", :R5, "HDOC" ],
  [ "config/cucumber.yml", "3dc1b6c268f7993e21c3306e0e9719a6963faf9875ac06e4875f47d285a3a597", :R5, "HDOC" ],
  [ "gherkin_specs/README.md", "e2fdba81e2800216e04d97f770b52453305edee039350128d258d5a7434f3a6c", :R5, "HDOC" ],
  [ "gherkin_specs/support/env.rb", "fd9586dc27ed3bcca2a5beb43fe196580e35af16df8fd1873eb4ebbf5ddfbb76", :R5, "HDOC" ],
  [ "gherkin_specs/support/.gitkeep", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", :R5, "HDOC" ],
  [ "gherkin_specs/step_definitions/.gitkeep", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", :R5, "HDOC" ],
  [ ".github/pull_request_template.md", "7ea1ad1ce12f07cc850a0ee61a754bd039fc849759bc65cc97207e34d4258105", :R8, "HDOC" ],
  [ "docs/tech_design_docs/README.md", "35e16dd26a0ce0159ad7a93529512c122fbfb12f8bad5e55a811f04b5596b835", :R8, "HDOC" ],
  [ "packs/README.md", "503d96f962d8a551c180ed6f20d48905d243408c5070a98b36ae05bf719a1ca8", :R8, "HDOC" ],
  [ "config/initializers/sentry.rb", "8c3ea6d595e6f8c32816727a55e1dad2c112de0849d5ba778d9c28cc8ff8c3d6", :R7, "HDOC+provenance(#77)" ]
].freeze

RAIL_IDS = %w[R1 R2 R3 R4 R5 R6 R7 R8 R9].freeze

# ---------------------------------------------------------------------------
# Small rail accumulator
# ---------------------------------------------------------------------------
class Rail
  attr_reader :gaps, :deviations, :note

  def initialize
    @gaps = []
    @deviations = []
    @note = nil
  end

  def gap(msg) = @gaps << msg
  def deviation(msg) = @deviations << msg
  def conform(msg) = @note = msg

  def verdict
    return :gap if @gaps.any?
    return :deviation if @deviations.any?
    :conform
  end

  def reason
    case verdict
    when :gap then "GAP: " + @gaps.join("; ")
    when :deviation then "DEVIATION: " + @deviations.join("; ")
    else "CONFORM — " + @note.to_s
    end
  end
end

def lock_gem(name)
  lock = File.read("Gemfile.lock")
  m = lock.match(/\n    #{Regexp.escape(name)} \(([\d.]+)\)/)
  m && m[1]
end

def file_sha256(path)
  return nil unless File.exist?(path)
  Digest::SHA256.file(path).hexdigest
end

def check_artifacts(rail, rail_id)
  ARTIFACTS.each do |path, sha, artifact_rail_id, _ref|
    next unless artifact_rail_id == rail_id
    actual = file_sha256(path)
    if actual.nil?
      rail.gap("ported artifact missing: #{path}")
    elsif actual != sha
      rail.gap("byte-identity drift: #{path} sha256 #{actual[0, 12]}… != pinned #{sha[0, 12]}…")
    end
  end
end

# ---------------------------------------------------------------------------
# Rails boot (test env; boot is lazy and never opens a DB connection)
# ---------------------------------------------------------------------------
@rails_boot_error = nil
def rails_app
  return if @rails_boot_error
  ENV["RAILS_ENV"] = "test"
  require File.join(ROOT, "config/environment")
rescue Exception => e
  @rails_boot_error = "#{e.class}: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# R1 — the boring stack
# ---------------------------------------------------------------------------
def rail_r1
  rail = Rail.new
  missing = %w[pg puma importmap-rails turbo-rails stimulus-rails view_component tailwindcss-rails]
                 .reject { |g| lock_gem(g) }
  rails_version = lock_gem("rails")
  missing << "rails 8.x (found #{rails_version})" unless rails_version&.start_with?("8.")
  rail.gap("R1 stack gems absent from Gemfile.lock: #{missing.join(', ')}") if missing.any?
  rail.gap("sidekiq absent from Gemfile.lock (R1 job substrate)") unless lock_gem("sidekiq")

  unless lock_gem("haml-rails")
    rail.deviation("HAML not adopted — transition deprioritized (PRD 0006 Q1; ticket #84 open)")
  end

  if lock_gem("aasm")
    rail.gap("aasm present in Gemfile.lock — contradicts Q7 (aasm is not adopted)")
  elsif lock_gem("state_machines-activerecord")
    rail.deviation("aasm not adopted; state_machines-activerecord is the state-machine substrate (PRD 0006 Q7)")
  else
    rail.gap("neither aasm nor state_machines-activerecord in Gemfile.lock")
  end

  if %w[solid_queue solid_cache solid_cable].any? { |g| lock_gem(g) }
    rail.deviation("solid_* → Sidekiq retirement in progress (PRD 0006 Q5; ticket #85 open)")
  else
    rail.conform("Rails #{rails_version} + pg/puma/importmap/Turbo/Stimulus/ViewComponent/Tailwind + Sidekiq only")
  end
  rail
end

# ---------------------------------------------------------------------------
# R2 — Turbo liveness (the mechanism, not the artifact)
# ---------------------------------------------------------------------------
def rail_r2
  rail = Rail.new
  layout = Dir.glob("app/views/layouts/application.html.erb").map { |f| File.read(f) }.join("\n")
  gaps = []
  gaps << "HEAD <meta name=\"turbo-refresh-method\" content=\"morph\"> missing from the layout (the trigger)" unless
    layout.include?('<meta name="turbo-refresh-method" content="morph">')
  gaps << "javascript_importmap_tags missing from the layout head" unless layout.include?("javascript_importmap_tags")
  gaps << "config/importmap.rb does not pin stimulus" unless
    File.exist?("config/importmap.rb") && File.read("config/importmap.rb").include?("stimulus")
  controllers = Dir.glob("app/javascript/controllers/*_controller.js")
  gaps << "no Stimulus controllers under app/javascript/controllers/" if controllers.empty?
  gaps << "<body data-turbo-morph> marker missing from the layout" unless layout.match?(/<body[^>]*data-turbo-morph/)
  if gaps.empty?
    rail.conform("head morph meta + body marker + importmap/Stimulus wiring all present (#{controllers.size} controllers)")
  else
    gaps.each { |g| rail.gap(g) }
  end
  rail
end

# ---------------------------------------------------------------------------
# R3 — the command rail
# ---------------------------------------------------------------------------
def rail_r3
  rail = Rail.new
  path = "app/commands/application_command.rb"
  check_artifacts(rail, :R3)
  if File.exist?(path)
    src = File.read(path)
    rail.gap("application_command.rb does not define run_after_commit") unless src.include?("def run_after_commit")
  else
    rail.gap("application_command.rb missing")
  end

  command_files = (Dir.glob("app/commands/**/*.rb") + Dir.glob("packs/*/app/commands/**/*.rb"))
  command_files -= [ "app/commands/application_command.rb" ] # the base class itself declares the parent
  bypass = command_files.select { |f| File.read(f).match?(/<\s*GLCommand::Callable\b/) }
  bypass.each { |f| rail.gap("command bypasses the ApplicationCommand rail (direct GLCommand::Callable): #{f}") }

  app = rails_app
  if app.nil?
    rail.gap("Rails boot failed (fail-closed): #{@rails_boot_error}")
  else
    unless ApplicationCommand.ancestors.include?(GLCommand::Callable)
      rail.gap("loaded ApplicationCommand does not inherit GLCommand::Callable")
    end
  end
  rail.conform("ApplicationCommand byte-identical to the pin; run_after_commit defined; " \
               "no direct GLCommand::Callable commands (the 2 multi-step Chainables stay Chainable per #76)") if
    rail.verdict == :conform
  rail
end

# ---------------------------------------------------------------------------
# R4 — bounded contexts (probes the live app)
# ---------------------------------------------------------------------------
def rail_r4
  rail = Rail.new
  rail.gap("packwerk absent from Gemfile.lock") unless lock_gem("packwerk")
  rail.gap("packwerk.yml missing") unless File.exist?("packwerk.yml")

  app = rails_app
  if app.nil?
    rail.gap("Rails boot failed (fail-closed): #{@rails_boot_error}")
  else
    autoload_dirs = Rails.autoloaders.main.dirs.map { |d| File.expand_path(d.to_s) }
    pack_app_dirs = Dir.glob("packs/*/app/*").select { |d| File.directory?(d) }.map { |d| File.expand_path(d) }
    missing = pack_app_dirs - autoload_dirs
    missing.each { |d| rail.gap("pack autoload dir not on the autoload path: #{d}") }

    view_paths = Rails.application.config.action_view.paths.to_a.map { |p| File.expand_path(p.to_s) }
    pack_views = Dir.glob("packs/*/app/views").select { |d| File.directory?(d) }.map { |d| File.expand_path(d) }
    (pack_views - view_paths).each { |d| rail.gap("pack view dir not on the ActionView path: #{d}") }

    begin
      Growth::Goal
      Scheduling::FailedPostRetry
    rescue NameError => e
      rail.gap("cross-pack constant does not resolve: #{e.message}")
    end
  end

  if lock_gem("packs-rails")
    rail.deviation("pack wiring via the packs-rails gem rather than the template's hand-wired autoloader block (PRD 0006 Q8)")
  elsif File.read("config/application.rb").include?("packs/*/app/*")
    rail.conform("packwerk + hand-wired pack autoloading; all #{Dir.glob('packs/*/app/*').size} pack dirs live") if
      rail.verdict == :conform
  else
    rail.gap("no pack wiring found (neither packs-rails nor the template's autoloader block)")
  end
  rail
end

# ---------------------------------------------------------------------------
# R5 — the BDD pipeline
# ---------------------------------------------------------------------------
def rail_r5
  rail = Rail.new
  rail.gap("cucumber absent from Gemfile.lock") unless lock_gem("cucumber")
  rail.gap("gherkin_lint absent from Gemfile.lock") unless lock_gem("gherkin_lint")
  features = Dir.glob("gherkin_specs/**/*.feature")
  rail.gap("no .feature files under gherkin_specs/") if features.empty?
  check_artifacts(rail, :R5)
  rail.conform("cucumber + gherkin_lint in the lockfile; #{features.size} feature files; lane config byte-identical to the pin") if
    rail.verdict == :conform
  rail
end

# ---------------------------------------------------------------------------
# R6 — the quality gates
# ---------------------------------------------------------------------------
def verify_members
  members = []
  File.read("bin/verify").each_line do |line|
    m = line.match(/run_gate "([^"]+)"/)
    members << m[1] if m
    members << "rspec" if line.match?(/\bAGENT_TEST=1\s+bin\/rspec\b/)
  end
  members
end

def rail_r6
  rail = Rail.new
  check_artifacts(rail, :R6)
  unless File.exist?("bin/verify")
    rail.gap("bin/verify missing")
    return rail
  end
  unless File.executable?("bin/verify")
    rail.gap("bin/verify is not executable")
  end

  members = verify_members
  # The template (ordered) set, with the turbo-carnival adjustments: the
  # single lint entry point (PRD 0006 R8 / ticket #91) consolidates
  # rubocop + erb_lint into the `lint` member; the BDD lane (Q2, ratified)
  # and the parity gate (W1.4 / #90) are additions.
  expected = %w[lint brakeman bundler-audit packwerk rspec]
  if Dir.glob("gherkin_specs/**/*.feature").any?
    expected += %w[cucumber gherkin_lint]
  end
  expected += %w[rswag:verify] if Dir.exist?("swagger")
  found = members.select { |m| expected.include?(m) }
  if found != expected
    rail.gap("bin/verify gate membership drifts from the template (ordered) set: expected #{expected.join(' -> ')}, found #{found.join(' -> ')}")
  end
  rail.gap("rspec gate does not run the agent-signal entry point (AGENT_TEST=1 bin/rspec)") unless
    File.read("bin/verify").match?(/\bAGENT_TEST=1\s+bin\/rspec\b/)

  ci = File.read(".github/workflows/ci.yml")
  %w[bin/verify cucumber gherkin_lint].each do |needle|
    rail.gap("CI workflow does not run #{needle}") unless ci.include?(needle)
  end
  rail.conform("bin/verify members in the template's relative order (incl. the BDD lane + parity gate); " \
               "agent-signal rspec; CI runs the gate + the BDD lane; ported artifacts byte-identical to the pin") if
    rail.verdict == :conform
  rail
end

# ---------------------------------------------------------------------------
# R7 — observability
# ---------------------------------------------------------------------------
def rail_r7
  rail = Rail.new
  check_artifacts(rail, :R7)
  rail.gap("sentry-rails absent from Gemfile.lock") unless lock_gem("sentry-rails")

  init = "config/initializers/sentry.rb"
  if File.exist?(init)
    src = File.read(init)
    rail.gap("sentry.rb does not call Sentry.init") unless src.include?("Sentry.init")
    rail.gap("sentry.rb does not read the DSN from encrypted credentials") unless
      src.match?(/credentials/) && src.match?(/sentry_dsn/)
  else
    rail.gap("config/initializers/sentry.rb missing")
  end
  rail.gap("config/credentials/production.yml.enc missing (the DSN lives in encrypted credentials)") unless
    File.exist?("config/credentials/production.yml.enc")

  plaintext = Dir.glob("config/**/*.{rb,yml,yml.enc,env*}")
  plaintext = plaintext.select { |f| File.file?(f) && File.read(f).match?(/https:\/\/[a-z0-9]+@[a-z0-9.-]+sentry\.io/i) }
  plaintext.each { |f| rail.gap("plaintext Sentry DSN committed: #{f}") }

  telemetry = "lib/charter_telemetry.rb"
  if File.exist?(telemetry)
    src = File.read(telemetry)
    rail.gap("charter gauge missing: growth.followers") unless src.include?('Sentry::Metrics.gauge("growth.followers"')
    rail.gap("charter gauge missing: growth.required_per_day") unless src.include?('Sentry::Metrics.gauge("growth.required_per_day"')
  else
    rail.gap("lib/charter_telemetry.rb missing (the charter gauges are not emitted)")
  end
  rail.conform("sentry-rails + initialiser wired to credentials; no plaintext DSN; charter gauges emitted; " \
               "artifact byte-identical to the pin modulo the #77 provenance header") if rail.verdict == :conform
  rail
end

# ---------------------------------------------------------------------------
# R8 — governance
# ---------------------------------------------------------------------------
def rail_r8
  rail = Rail.new
  check_artifacts(rail, :R8)
  %w[AGENTS.md FOUNDERS.md docs/prd/README.md].each do |f|
    rail.gap("governance file missing: #{f}") unless File.exist?(f)
  end

  thesis = File.read("THESIS.md") if File.exist?("THESIS.md")
  if thesis.nil?
    rail.gap("THESIS.md missing")
  else
    rail.gap("THESIS.md has no 'We will NOT' list") unless thesis.include?("We will NOT")
    rail.gap("THESIS.md is not marked CURRENT (it is inert)") unless thesis.match?(/\*\*Status:\*\* CURRENT/)
  end

  %w[ARCHITECTURE.md CONTRACTS.md OPS.md DESIGN.md].each do |f|
    rail.gap("doc home missing at the repo root: #{f}") unless File.exist?(f)
  end
  rail.gap("docs/tech_design_docs/ missing") unless File.directory?("docs/tech_design_docs")

  unless File.exist?("bin/lint")
    rail.deviation("single lint entry (bin/lint) + AGENTS.md content contract closing under approved ticket #91 (PRD 0006 R8)")
  end
  rail.conform("AGENTS.md hub + CURRENT THESIS with the 'We will NOT' list + FOUNDERS.md + root doc homes + " \
               "PR template and docs stubs byte-identical to the pin") if rail.verdict == :conform
  rail
end

# ---------------------------------------------------------------------------
# R9 — the API lane (dormant until an API surface exists)
# ---------------------------------------------------------------------------
def rail_r9
  rail = Rail.new
  if Dir.exist?("swagger")
    rail.gap("rswag-api absent from Gemfile.lock while swagger/ exists") unless lock_gem("rswag-api")
    rail.gap("rswag-specs absent from Gemfile.lock while swagger/ exists") unless lock_gem("rswag-specs")
    rail.gap("bin/verify does not run rswag:verify while swagger/ exists") unless verify_members.include?("rswag:verify")
    rail.conform("rswag lane live: swagger/ + gems + rswag:verify gate member") if rail.verdict == :conform
  else
    rail.deviation("rswag lane not adopted — no API surface exists yet (PRD 0006 R9: N/A until an API does)")
  end
  rail
end

RAIL_CHECKS = {
  "R1" => :rail_r1,
  "R2" => :rail_r2,
  "R3" => :rail_r3,
  "R4" => :rail_r4,
  "R5" => :rail_r5,
  "R6" => :rail_r6,
  "R7" => :rail_r7,
  "R8" => :rail_r8,
  "R9" => :rail_r9
}.freeze

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
skip = ENV.fetch("PARITY_AUDIT_SKIP", "").split(",").map(&:strip)
verdicts = {}
RAIL_CHECKS.each do |id, method_name|
  next if skip.include?(id)
  begin
    verdicts[id] = send(method_name)
  rescue Exception => e
    verdicts[id] = Rail.new.tap { |r| r.gap("probe error (fail-closed): #{e.class}: #{e.message}") }
  end
end

missing = RAIL_IDS - verdicts.keys
unless missing.empty?
  puts "PARITY ERROR — no disposition for #{missing.join(', ')} (a rail must never be silently missing)"
  exit 2
end

RAIL_IDS.each do |id|
  r = verdicts[id]
  detail = r.reason.sub(/\A(?:GAP: |DEVIATION: |CONFORM — )/, "")
  puts format("%-2s  %-11s  %s", id, r.verdict.to_s.upcase, detail)
end

gaps = RAIL_IDS.select { |id| verdicts[id].verdict == :gap }
deviations = RAIL_IDS.select { |id| verdicts[id].verdict == :deviation }
conforms = RAIL_IDS.select { |id| verdicts[id].verdict == :conform }

if gaps.empty?
  puts "PARITY OK — #{conforms.size} CONFORM, #{deviations.size} DEVIATION, 0 GAP (template pin #{GENERATOR_PIN[0, 10]}…)"
  exit 0
else
  puts "PARITY FAILED — GAP on #{gaps.join(', ')} (pin #{GENERATOR_PIN[0, 10]}…)"
  exit 1
end
