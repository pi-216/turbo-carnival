# frozen_string_literal: true

# spec/support/agent_test_quiet.rb — keep the agent test signal a SIGNAL.
#
# The agent signal contract (bin/rspec + lib/rspec/agent_formatter.rb, ported
# byte-identical from rails-venture-template 8dc4586b941a) is a claim about
# STDOUT: lane A carries the verdict line and nothing else. The formatter can
# only own the output RSpec itself emits, so application output written to the
# process's $stdout bypasses it and lands in the same channel.
#
# In turbo-carnival the emitters are rake task bodies, which print human-facing
# progress banners with `puts`:
#
#   * packs/scheduling/lib/tasks/scheduled_posting.rake — the still rail runner
#     plus its CollectPostInsights summary;
#   * packs/scheduling/lib/tasks/reel_posting.rake      — the reel rail runner;
#   * lib/tasks/hashtags.rake                           — the untagged-post filler;
#   * lib/tasks/captions.rake.
#
# plus Sidekiq's one-line connection banner, written by Sidekiq's own logger on
# the first client connection.
#
# Measured 2026-10-20 on a green 830-example run before this file existed: the
# verdict arrived buried under 6,800 B of that output. Ticket #19's acceptance
# criterion is a single line under 200 B.
#
# Those banners are correct in production and in a developer's terminal, so this
# file acts ONLY while the agent signal is active (`AGENT_TEST=1` — set by
# bin/verify, CI, and the unobserved cron agents the signal exists for). It
# REROUTES application output to tmp/agent-test/app-output.log rather than
# discarding it: the signal stays a lens over a complete record, and CI uploads
# that file beside the rspec report.
#
# Rails.logger is deliberately NOT touched here: it already broadcasts to
# log/test.log only and never reached stdout.
#
# The caller's real stdout is pinned by OBJECT REFERENCE *before* the swap,
# because RSpec's formatter holds that reference — reassigning the $stdout
# global afterwards cannot move the verdict off the caller's stream.

if ENV["AGENT_TEST"].to_s == "1"
  require "fileutils"

  app_output_path = Rails.root.join("tmp", "agent-test", "app-output.log")
  FileUtils.mkdir_p(app_output_path.dirname)

  app_output = File.open(app_output_path, "w")
  app_output.sync = true

  # 1. Pin RSpec's own streams to the real stdout/stderr FIRST.
  RSpec.configure do |config|
    config.output_stream = $stdout
    config.error_stream  = $stderr
  end

  # 2. Move application stdout (every rake task banner) off the verdict channel.
  $stdout = app_output

  # 3. Sidekiq's logger holds its own IO, so it does not follow the $stdout
  #    global; without this its connection banner is the last leak.
  if defined?(Sidekiq) && Sidekiq.respond_to?(:logger=)
    Sidekiq.logger = Sidekiq::Logger.new(app_output)
  end
end
