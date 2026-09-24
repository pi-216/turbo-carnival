# frozen_string_literal: true

module Growth
  # Read-only gate: fresh renders must only run while turbo-carnival holds a
  # live scheduler claim on the 4090 AND ComfyUI is answering. Reads
  # bin/comfyui_harness.sh status — the single source of truth for the
  # claim/ComfyUI lifecycle (see the turbo-carnival-development skill).
  #
  # Fail-closed: any error (script missing, scheduler unreachable, parse
  # failure) reports not-ready, so the harness NEVER assumes ComfyUI is
  # available without a claim.
  class SchedulerGate
    Result = Struct.new(:claimed, :ours, :comfyui_up, :raw, keyword_init: true) do
      def ready?
        ours && comfyui_up
      end

      # idle | ours | other
      def claim_state
        return 'idle' unless claimed

        ours ? 'ours' : 'other'
      end
    end

    STATUS_SCRIPT = Rails.root.join('bin/comfyui_harness.sh')

    def self.status
      require 'open3'
      out, err, st = Open3.capture3(STATUS_SCRIPT.to_s, 'status')
      return parse(out) if st.success? && out.present?

      Result.new(claimed: false, ours: false, comfyui_up: false, raw: "script error (#{st.exitstatus}): #{err.strip}")
    rescue StandardError => e
      Result.new(claimed: false, ours: false, comfyui_up: false, raw: e.message)
    end

    def self.parse(line)
      m = line.to_s.match(/claim=(\S+)\s+job=(\S+)\s+ours=(\S+)\s+comfyui=(\S+)/)
      return nil unless m

      _, _, ours, comfy = m.captures
      Result.new(
        claimed: m[1] != 'idle',
        ours: ours == 'yes',
        comfyui_up: comfy == 'up',
        raw: line.strip
      )
    end
  end
end
