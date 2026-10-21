# frozen_string_literal: true

module Growth
  # Photo-realism / quality MEASUREMENT for turbo-carnival: an AVA-trained
  # aesthetics predictor (shunk031/aesthetics-predictor-v1-vit-large-patch14,
  # ViT-L/14) plus a pure-numpy sharpness (Laplacian variance), both run CPU-only
  # through the ComfyUI venv python.
  #
  # PRD 0007 B3 (founder ruling 2026-10-19: "Let's go with those values. We can
  # keep assets that we think crossed the border for re-valuation at a later
  # time."): this is a MEASUREMENT, never a veto. It does not reject, purge or
  # hold anything, and no caller may turn `flagged` back into a veto -- the
  # selection layer and the founder's tier pre-flight decide what is used, and an
  # asset that crossed the border is KEPT for re-valuation. Same posture as
  # Growth::NsfwGate after PRD 0007 A1; realism was the LAST veto in the render
  # stack, so a fresh render now reaches the library on its measurements alone.
  #
  # `flagged` is the verdict OF RECORD at the selection defaults in force when the
  # image was scored: true when a measured score sits below its default. Those
  # defaults are the SELECTION defaults -- they order the pool (low quality last,
  # see Photos::ListAvailable) and they never block a render. They are deliberately
  # NOT persisted on the asset: a threshold change re-orders the pool from the raw
  # scores instead of freezing a verdict computed under an older default (contrast
  # `photos.nsfw_flagged`, which is a compliance verdict of record).
  #
  # Fail-OPEN, deliberately: a missing image, a missing model, a dead python or a
  # timeout leaves the scores UNMEASURED (nil, with the reason in `error`) and the
  # render proceeds, with a loud per-run log line. Realism is not a floor control
  # (PRD 0007 §1 is: the age gate, no real-person likeness, the synthetic mark,
  # pacing/duplicate), so it must not fail closed. NULL != 0: an unmeasured score
  # is not a low one, and the selection layer must not read it as either.
  #
  # Env knobs (read at call time so they're runtime-tunable):
  #   AESTHETIC_MODEL_DIR       model path
  #                             (default /mnt/nas-ai-models/gates/
  #                              aesthetics-predictor-v1-vit-large-patch14)
  #   AESTHETIC_PYTHON          python with torch+transformers (default ComfyUI venv)
  #   AESTHETIC_GATE_SCRIPT     scoring script (default Rails bin/aesthetics_gate.py)
  #   AESTHETIC_THRESHOLD       SELECTION default for the aesthetic score (default 4.5)
  #   SHARPNESS_THRESHOLD       SELECTION default for sharpness (default 30.0)
  #   AESTHETIC_GATE_DISABLED=1  skip the measurement entirely (scores stay unmeasured)
  class RealismGate
    DEFAULT_MODEL_DIR = '/mnt/nas-ai-models/gates/aesthetics-predictor-v1-vit-large-patch14'
    DEFAULT_PYTHON    = '/mnt/fscache/essdee/ComfyUI/venv/bin/python'
    # The selection defaults PRD 0007 B3 confirms. They are DEFAULTS, not rails:
    # override them with the env knobs above.
    DEFAULT_AESTHETIC_THRESHOLD = 4.5
    DEFAULT_SHARPNESS_THRESHOLD = 30.0
    TIMEOUT_S = 120 # first call includes model load from disk

    # No `safe` member, on purpose -- the same rule Growth::NsfwGate records: the
    # result is a measurement, and a boolean named "safe" on it is how an advisory
    # score gets read as a veto again. `flagged` is what the selection layer reads;
    # `measured?` separates "scored low" from "never scored" (a nil score is
    # unknown, not zero).
    Result = Struct.new(:aesthetic_score, :sharpness, :flagged, :reason, :error, keyword_init: true) do
      def measured?
        !aesthetic_score.nil? || !sharpness.nil?
      end
    end

    # @param image_path [String] absolute path to the rendered image
    # @return [Result] a measurement: a low score is not a rejection and a high one
    #   is not a licence. Callers persist it and carry on.
    def call(image_path:)
      return Result.new if disabled?

      unless File.file?(image_path)
        return Result.new(error: "image missing: #{image_path}")
      end
      unless File.directory?(model_dir)
        return Result.new(error: "aesthetic model dir missing: #{model_dir}")
      end

      out = run_scorer(image_path)
      aesthetic = out['aesthetic_score'].presence&.to_f
      sharp = out['sharpness'].presence&.to_f
      Result.new(
        aesthetic_score: aesthetic,
        sharpness: sharp,
        flagged: flagged?(aesthetic, sharp),
        reason: out['reason'],
        error: out['error']
      )
    rescue StandardError => e
      Result.new(error: "#{e.class}: #{e.message}")
    end

    # The SELECTION defaults, as CLASS-level readers: the selection layer
    # (Photos::ListAvailable) orders the pool by them, and a query object must not have
    # to instantiate the scorer -- with its model dir and python path -- to learn two
    # numbers. Both read ENV at call time, so ONE knob moves this gate's `flagged`
    # verdict and the ordering together instead of letting them drift apart.
    def self.aesthetic_threshold
      ENV.fetch('AESTHETIC_THRESHOLD', DEFAULT_AESTHETIC_THRESHOLD.to_s).to_f
    end

    def self.sharpness_threshold
      ENV.fetch('SHARPNESS_THRESHOLD', DEFAULT_SHARPNESS_THRESHOLD.to_s).to_f
    end

    def model_dir
      ENV.fetch('AESTHETIC_MODEL_DIR', DEFAULT_MODEL_DIR)
    end

    # The SELECTION default for the aesthetic score: an asset below it is
    # low-priority in the pool, never rejected.
    def aesthetic_threshold
      self.class.aesthetic_threshold
    end

    # The SELECTION default for sharpness (Laplacian variance).
    def sharpness_threshold
      self.class.sharpness_threshold
    end

    private

    def disabled?
      ENV['AESTHETIC_GATE_DISABLED'] == '1'
    end

    # nil when nothing was measured -- unmeasured is NOT "below the default" -- else
    # whether ANY measured score sits below its selection default.
    def flagged?(aesthetic_score, sharpness)
      return nil if aesthetic_score.nil? && sharpness.nil?

      below = []
      below << aesthetic_score if !aesthetic_score.nil? && aesthetic_score < aesthetic_threshold
      below << sharpness if !sharpness.nil? && sharpness < sharpness_threshold
      below.any?
    end

    def python_bin
      ENV.fetch('AESTHETIC_PYTHON', DEFAULT_PYTHON)
    end

    def script
      ENV.fetch('AESTHETIC_GATE_SCRIPT', Rails.root.join('bin/aesthetics_gate.py').to_s)
    end

    def run_scorer(image_path)
      stdout, stderr, status = nil
      Timeout.timeout(TIMEOUT_S) do
        stdout, stderr, status = Open3.capture3(
          python_bin, script, '--model', model_dir,
          '--aesthetic-threshold', aesthetic_threshold.to_s,
          '--sharpness-threshold', sharpness_threshold.to_s,
          '--image', image_path
        )
      end
      line = stdout.to_s.lines.map(&:strip).find { |l| l.start_with?('{') }
      raise "aesthetic gate failed (exit=#{status.exitstatus}): #{stderr.to_s[0, 300]}" unless line

      JSON.parse(line).with_indifferent_access
    rescue Errno::ENOENT => e
      raise "aesthetic gate python missing: #{e.message}"
    end
  end
end
