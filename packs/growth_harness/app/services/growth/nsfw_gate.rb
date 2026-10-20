# frozen_string_literal: true

module Growth
  # Third-party NSFW classifier (Falconsai/nsfw_image_detection, ViT-base via
  # ComfyUI's venv torch, CPU-only) -- an ADVISORY MEASUREMENT, never a veto.
  #
  # PRD 0007 A1, founder ruling 2026-10-19 ("0.5 as the flag-only threshold and no
  # auto-action at any score"): the gate measures, records and returns. It does not
  # reject, purge or hold anything, and no caller may turn `flagged` back into a
  # veto -- the selection layer and the founder's tier pre-flight decide what is
  # used, and assets that crossed the border are KEPT for re-valuation.
  #
  # `flagged` is the verdict OF RECORD at the threshold in force when the image was
  # scored. It is persisted on the asset row beside the score, so a later threshold
  # change re-scores assets explicitly instead of silently rewriting what the
  # record says.
  #
  # Fail-OPEN, deliberately: a missing image, a missing model, a dead python or a
  # timeout leaves the score UNMEASURED (nil score, with the reason in `error`) and
  # the render proceeds. This is not a floor control -- the floor (PRD 0007 §1) is
  # the age gate, no real-person likeness, the synthetic mark and platform
  # compliance, and all of those stay fail-closed. But an unmeasured score must be
  # LOUD: callers log it per run and the asset row keeps `nsfw_score` NULL, because
  # unmeasured is not "safe" (the same rule as `photos.synthetic`).
  #
  # Env knobs (read at call time so they're runtime-tunable):
  #   NSFW_MODEL_DIR    model path (default /mnt/nas-ai-models/gates/nsfw_image_detection)
  #   NSFW_PYTHON       python with torch+transformers (default ComfyUI venv)
  #   NSFW_GATE_SCRIPT  classifier script (default Rails bin/nsfw_gate.py)
  #   NSFW_THRESHOLD    FLAG threshold -- advisory only (default 0.5)
  #   NSFW_GATE_DISABLED=1  skip the measurement entirely (score stays unmeasured)
  class NsfwGate
    DEFAULT_MODEL_DIR = '/mnt/nas-ai-models/gates/nsfw_image_detection'
    DEFAULT_PYTHON    = '/mnt/fscache/essdee/ComfyUI/venv/bin/python'
    TIMEOUT_S = 90 # first call includes model load from disk

    # No `safe` member, on purpose: the result is a measurement, and a boolean named
    # "safe" on it is how an advisory score gets read as a veto again. `flagged` is
    # what the selection layer reads; `measured?` separates "scored low" from
    # "never scored" (a nil flag is unknown, not false).
    Result = Struct.new(:nsfw_score, :label, :flagged, :error, keyword_init: true) do
      def measured?
        !nsfw_score.nil?
      end
    end

    # @param image_path [String] absolute path to the rendered image
    # @return [Result] a measurement: a low score is not a licence, a high score is
    #   not a rejection. Callers persist it and carry on.
    def call(image_path:)
      return Result.new if disabled?

      unless File.file?(image_path)
        return Result.new(error: "image missing: #{image_path}")
      end
      unless File.directory?(model_dir)
        return Result.new(error: "nsfw model dir missing: #{model_dir}")
      end

      out = run_classifier(image_path)
      score = out['nsfw_score'].presence&.to_f
      Result.new(
        nsfw_score: score,
        label: out['label'],
        flagged: score.nil? ? nil : score >= threshold,
        error: out['error']
      )
    rescue StandardError => e
      Result.new(error: "#{e.class}: #{e.message}")
    end

    def model_dir
      ENV.fetch('NSFW_MODEL_DIR', DEFAULT_MODEL_DIR)
    end

    # The FLAG threshold: the score at or above which an asset is recorded as having
    # crossed the border. It changes nothing about what is used -- flagged assets are
    # kept and re-valuable, never actioned automatically.
    def threshold
      ENV.fetch('NSFW_THRESHOLD', '0.5').to_f
    end

    private

    def disabled?
      ENV['NSFW_GATE_DISABLED'] == '1'
    end

    def python_bin
      ENV.fetch('NSFW_PYTHON', DEFAULT_PYTHON)
    end

    def script
      ENV.fetch('NSFW_GATE_SCRIPT', Rails.root.join('bin/nsfw_gate.py').to_s)
    end

    def run_classifier(image_path)
      stdout, stderr, status = nil
      Timeout.timeout(TIMEOUT_S) do
        stdout, stderr, status = Open3.capture3(
          python_bin, script, '--model', model_dir,
          '--threshold', threshold.to_s,
          '--image', image_path
        )
      end
      line = stdout.to_s.lines.map(&:strip).find { |l| l.start_with?('{') }
      raise "nsfw gate failed (exit=#{status.exitstatus}): #{stderr.to_s[0, 300]}" unless line

      JSON.parse(line).with_indifferent_access
    rescue Errno::ENOENT => e
      raise "nsfw gate python missing: #{e.message}"
    end
  end
end
