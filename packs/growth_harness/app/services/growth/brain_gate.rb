# frozen_string_literal: true

module Growth
  # Read-only gate: the planning phase must only run while turbo-carnival holds a
  # live scheduler claim on the 4090 AND the local brain (llama-server) is
  # answering. Mirrors Growth::SchedulerGate for the ComfyUI/render phase; reads
  # bin/brain_harness.sh status — the single source of truth for the brain's
  # claim/server lifecycle (PRD 0001, ticket #24).
  #
  # Fail-closed: any error (script missing, scheduler unreachable, parse failure)
  # reports not-ready, so the brain is NEVER assumed available without a claim.
  class BrainGate
    Result = Struct.new(:claimed, :ours, :brain_up, :raw, keyword_init: true) do
      def ready?
        ours && brain_up
      end

      # idle | ours | other
      def claim_state
        return 'idle' unless claimed

        ours ? 'ours' : 'other'
      end
    end

    STATUS_SCRIPT = Rails.root.join('bin/brain_harness.sh')

    def self.status
      require 'open3'
      out, err, st = Open3.capture3(STATUS_SCRIPT.to_s, 'status')
      return parse(out) if st.success? && out.present?

      Result.new(claimed: false, ours: false, brain_up: false, raw: "script error (#{st.exitstatus}): #{err.strip}")
    rescue StandardError => e
      Result.new(claimed: false, ours: false, brain_up: false, raw: e.message)
    end

    def self.parse(line)
      m = line.to_s.match(/claim=(\S+)\s+job=(\S+)\s+ours=(\S+)\s+brain=(\S+)/)
      return nil unless m

      _, _, ours, brain = m.captures
      Result.new(
        claimed: m[1] != 'idle',
        ours: ours == 'yes',
        brain_up: brain == 'up',
        raw: line.strip
      )
    end

    # Surface the refusal as an auditable decision row, exactly as the render
    # phase does for comfyui_unclaimed (Growth::ContentGenerator#record_unclaimed).
    # Records only when the gate is NOT ready; never raises into the caller.
    def self.record_unclaimed!(goal:, gate: status)
      return if gate.ready?

      Growth::Decision.create!(
        goal: goal,
        action: 'brain_unclaimed',
        reason: "plan phase skipped — no brain claim (#{gate.claim_state}, brain #{gate.brain_up ? 'up' : 'down'}) | #{gate.raw}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::BrainGate brain_unclaimed: #{gate.raw}")
      true
    rescue StandardError => e
      Rails.logger.error("Growth::BrainGate could not log brain_unclaimed: #{e.message}")
      false
    end
  end
end
