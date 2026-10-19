# frozen_string_literal: true

module Growth
  # Read-only gate for the 4090's phase transitions (PRD 0001, ticket #25).
  #
  # The brain (~22 GiB) and ComfyUI (~23 GiB) cannot be co-resident on a 24 GiB
  # card. Entering either phase requires (a) the OUTGOING tenant to be verified
  # down and (b) a measured free-VRAM reading on the device to clear the incoming
  # floor. This class reads bin/phase_handoff.sh check — the single source of
  # truth for the decision — and, like BrainGate/SchedulerGate, fails CLOSED: an
  # unreadable device or an unparseable line parks the phase, it never admits it.
  #
  # It never inspects a process exit code or a pid as evidence of freed memory:
  # CUDA holds VRAM briefly after exit, so the only freeness signal is the device
  # reading the harness took.
  class PhaseHandoff
    Result = Struct.new(:phase, :outgoing, :tenant_state, :free_mib, :floor_gib,
                        :verdict, :raw, keyword_init: true) do
      def ready?
        verdict == 'proceed'
      end

      # The reason a parked phase names, e.g. vram_insufficient | tenant_resident.
      def park_reason
        verdict.to_s.sub(/\Apark:/, '')
      end
    end

    STATUS_SCRIPT = Rails.root.join('bin/phase_handoff.sh')

    # phase: :render (outgoing = brain) or :brain (outgoing = comfyui).
    def self.check(phase: :render)
      require 'open3'
      out, err, st = Open3.capture3(STATUS_SCRIPT.to_s, 'check', phase.to_s)
      # `check` exits 3 on a park, so stdout — not the exit status — carries the
      # verdict. Parse it whenever present; only a truly empty line is an error.
      return parse(out) if out.present?

      Result.new(phase: phase.to_s, verdict: 'park:vram_unreadable',
                 raw: "script error (#{st.exitstatus}): #{err.strip}")
    rescue StandardError => e
      Result.new(phase: phase.to_s, verdict: 'park:vram_unreadable', raw: e.message)
    end

    def self.parse(line)
      fields = line.to_s.scan(/(\w+)=(\S+)/).to_h
      return nil unless fields['phase'] && fields['verdict']

      free = fields['free'].to_s.sub(/MiB\z/, '')
      Result.new(
        phase: fields['phase'],
        outgoing: fields['outgoing'],
        tenant_state: fields['tenant'],
        free_mib: free.match?(/\A\d+\z/) ? free.to_i : nil,
        floor_gib: fields['floor'].to_s.sub(/GiB\z/, '').to_i,
        verdict: fields['verdict'],
        raw: line.strip
      )
    end

    # Surface a parked phase in the same decision ledger the render path already
    # uses for comfyui_unclaimed / brain_unclaimed. A refused batch is a normal
    # outcome (PRD 0001), so it is recorded, never raised. No-op when ready.
    def self.record_insufficient!(goal:, result: check)
      return if result.ready?

      Growth::Decision.create!(
        goal: goal,
        action: 'vram_insufficient',
        reason: "phase #{result.phase} parked (#{result.park_reason}) — " \
                "outgoing #{result.outgoing} #{result.tenant_state}, " \
                "free #{result.free_mib ? "#{result.free_mib}MiB" : 'unreadable'}, " \
                "floor #{result.floor_gib}GiB | #{result.raw}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::PhaseHandoff vram_insufficient: #{result.raw}")
      true
    rescue StandardError => e
      Rails.logger.error("Growth::PhaseHandoff could not log vram_insufficient: #{e.message}")
      false
    end
  end
end
