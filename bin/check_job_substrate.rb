#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/check_job_substrate.rb — gate for PRD 0006 Q5 (ticket #85): the job
# substrate is Sidekiq only, with the ActiveJob adapter set to :sidekiq.
#
#   ruby bin/check_job_substrate.rb           # check the live repo
#   ruby bin/check_job_substrate.rb <dir>     # check a fixture tree (specs)
#
# Fails (exit 1) if a solid_* reference reappears in the Gemfile, Gemfile.lock
# or config/, or if any config/ file assigns an ActiveJob adapter other than
# :sidekiq, or if no adapter is configured at all. Fail-closed: a missing
# target directory is an error, never a pass. Exit 0 = conform.
#
# It scans code/config substrate files only — Gemfile, Gemfile.lock, and
# config/** — never prose docs, so a historical mention in a doc cannot trip it.

root = ARGV.fetch(0, File.expand_path("..", __dir__))

SOLID_TOKENS = %w[solid_queue solid_cache solid_cable SolidQueue SolidCache SolidCable].freeze

def scan_files(root)
  files = %w[Gemfile Gemfile.lock].map { |f| File.join(root, f) }
  files.select { |f| File.exist?(f) }.tap do |out|
    config_dir = File.join(root, "config")
    if Dir.exist?(config_dir)
      Dir.glob(File.join(config_dir, "**", "*.{rb,yml,yaml}")).each { |f| out << f }
    end
  end
end

violations = []

unless File.exist?(File.join(root, "Gemfile"))
  violations << "no Gemfile at #{root} (fail-closed: target is not a repo tree)"
end

files = scan_files(root)
files.each do |path|
  content = File.read(path)
  SOLID_TOKENS.each do |token|
    next unless content.include?(token)

    line = content.lines.find { |l| l.include?(token) }&.strip
    violations << "#{path}: solid_* reference #{token.inspect} (#{line})"
  end
end

adapter_files = Dir.glob(File.join(root, "config", "**", "*.rb"))
adapter_assignments = adapter_files.filter_map do |path|
  content = File.read(path)
  matches = content.scan(/queue_adapter\s*=\s*:(\w+)/)
  matches.map { |m| [path, m.first] }
end.flatten(1)

if adapter_assignments.empty?
  violations << "config/: no active_job.queue_adapter configured (must be :sidekiq)"
else
  adapter_assignments.each do |path, adapter|
    violations << "#{path}: ActiveJob adapter is :#{adapter}, not :sidekiq" unless adapter == "sidekiq"
  end
end

if violations.empty?
  puts "job_substrate OK: Sidekiq is the sole job substrate, adapter is :sidekiq"
  exit 0
else
  puts "job_substrate FAILED (#{violations.size} violation(s)):"
  violations.each { |v| puts "  - #{v}" }
  exit 1
end
