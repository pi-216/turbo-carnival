# frozen_string_literal: true

# lib/rspec/agent_formatter.rb — agent-facing RSpec formatter (two-lane output).
#
# Test runs are typically fired by UNOBSERVED cron jobs: there is no terminal and no
# redirect, and the agent's captured stdout becomes its context window. A default
# rspec run therefore prefills the model with kilobytes of progress dots, warnings and
# framework backtrace that it must read but cannot act on.
#
# This formatter splits a run into two lanes:
#
#   lane A (stdout, owned here) — the compact signal: a verdict line plus, when red,
#           the identity and diff of each distinct failure, capped. This is all the
#           model should need.
#   lane B (a file opened here) — the complete, UNTRUNCATED record: every failure
#           group, every body line, every backtrace frame. Written by the formatter's
#           own handle, so it exists even when rspec dies mid-load.
#
# The signal is a LENS over lane B; a light signal is never a dead end. Any verdict
# can be resolved by reading the log path the caller prints.
#
# Genome alignment:
#   Signal Fidelity       — lane A carries only target-relevant signal.
#   Pipeline Silence      — 0 examples executed => TESTS ZERO, never a quiet pass.
#   Probe False Positive  — "TESTS OK" requires a completed summary with 0 failures
#                           AND 0 errors outside examples. A load error or an abort
#                           reports UNKNOWN, so OK cannot be produced by silence.
#
# Verdict vocabulary (stable contract — agents grep for these prefixes):
#   TESTS OK      <n> examples, 0 failures
#   TESTS RED     <n> examples, <f> failures, <d> distinct
#   TESTS ZERO    0 examples ran — NOT a pass (bad filter/path)
#   TESTS UNKNOWN run aborted / no summary emitted — NOT a pass

class AgentFormatter
  RSpec::Core::Formatters.register self, :start, :message, :example_failed, :dump_summary, :close

  MAX_GROUPS = 8    # distinct failure signatures shown on stdout
  MAX_BODY   = 12   # body lines per group on stdout
  MAX_TRACE  = 2    # backtrace frames per group on stdout

  def initialize(output)
    @output     = output
    @groups     = {}
    @summarized = false
    @fatal      = nil

    @full_path = ENV["AGENT_TEST_DETAIL"] || "tmp/agent-test/rspec-detail.log"
    begin
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(@full_path))
      @full = File.open(@full_path, "w")
    rescue StandardError
      @full = nil # lane B is a bonus; its absence must never break a run
    end
  end

  def start(_notification)
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # RSpec routes "No examples found.", load errors, progress dots and other pre-run
  # notices here. They are NOISE for lane A — the verdict is classified from the
  # summary instead — but they belong in lane B, the complete record. Never echo to
  # stdout: that is the leak that puts kilobytes of warnings into the model's context.
  def message(notification)
    text = notification.message.to_s
    @fatal ||= text.lines.find { |l| l =~ /An error occurred while loading|LoadError|RuntimeError/ }
    @full&.puts text.each_line.map(&:chomp)
  end

  def example_failed(notification)
    example = notification.example
    error   = example.exception
    key     = [ error.class.name, notification.message_lines.join("\n") ]

    group = (@groups[key] ||= {
      count: 0,
      location: example.location,
      description: example.full_description,
      body: notification.message_lines,        # UNTRUNCATED — lane B
      trace: notification.formatted_backtrace  # UNTRUNCATED — lane B
    })
    group[:count] += 1

    @full&.puts "FAIL #{example.location}  #{example.full_description}" \
                "#{group[:count] > 1 ? "  (x#{group[:count]})" : ""}"
    notification.message_lines.each { |l| @full&.puts "  #{l}" }
    notification.formatted_backtrace.each { |l| @full&.puts "  at #{l}" }
  end

  def dump_summary(summary)
    @summarized = true
    n = summary.example_count
    f = summary.failure_count
    p = summary.pending_count
    x = summary.errors_outside_of_examples_count.to_i
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @t0) * 1000).round
    tail = +""
    tail << ", #{p} pending" if p.positive?
    tail << ", #{x} errors outside examples" if x.positive?

    @full&.puts "SUMMARY #{n} examples, #{f} failures, #{p} pending, " \
                "#{x} outside-example errors (#{ms}ms)"
    @full&.flush

    if x.positive? && n.zero?
      # RSpec fires a summary even when it never ran a spec (a load error). Say what
      # actually happened rather than dressing it up as a suite failure.
      @output.puts "TESTS UNKNOWN — run aborted loading specs: 0 examples, " \
                   "#{x} outside-example errors (#{ms}ms). NOT a pass."
      @output.puts "  cause: #{@fatal.strip}" if @fatal
    elsif f.zero? && x.zero?
      if n.zero?
        # Pipeline-Silence guard: a run that executed nothing is NOT a pass.
        @output.puts "TESTS ZERO — 0 examples ran. Check filters/paths — this is NOT a pass."
      else
        @output.puts "TESTS OK — #{n} examples, 0 failures#{tail} (#{ms}ms)"
      end
    else
      @output.puts "TESTS RED — #{n} examples, #{f} failures, " \
                   "#{@groups.size} distinct#{tail} (#{ms}ms)"
      @groups.each_with_index do |((_, _), group), i|
        if i >= MAX_GROUPS
          @output.puts "  … +#{@groups.size - MAX_GROUPS} more distinct failures — see the full log"
          break
        end
        @output.puts "FAIL #{group[:location]}  #{group[:description]}" \
                     "#{group[:count] > 1 ? "   (x#{group[:count]})" : ""}"
        group[:body]
          .reject { |l| l.strip.empty? || l.match?(/compared using/) }
          .first(MAX_BODY)
          .each { |l| @output.puts "  #{l.sub(/\A\s*Failure\/Error:\s*/, 'code: ')}" }
        group[:trace].first(MAX_TRACE).each { |l| @output.puts "  at #{l}" }
      end
    end
  end

  def close(_notification)
    unless @summarized
      @output.puts "TESTS UNKNOWN — run did not complete (no summary emitted). NOT a pass."
    end
  ensure
    @full&.close
  end
end
