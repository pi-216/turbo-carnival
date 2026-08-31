# frozen_string_literal: true

module Growth
  # Photo-realism / quality gate for turbo-carnival. Runs a third-party
  # aesthetics predictor (shunk031/aesthetics-predictor-v1-vit-large-patch14,
  # AVA-trained ViT-L/14) plus a pure-numpy sharpness (Laplacian variance)
  # check via the ComfyUI venv python — all CPU-only, mirroring NsfwGate's
  # fail-closed contract. A freshly rendered image must pass BOTH the NSFW
  # gate AND this gate before it can enter the photo library / queue.
  #
  # Fail-closed: any error/missing model/missing python/timeout rejects.
  #
  # Env knobs (read at call time so they're runtime-tunable):
  #   AESTHETIC_MODEL_DIR      model path
  #                            (default /mnt/fscache/essdee/aesthetics-gate/
  #                             aesthetics-predictor-v1-vit-large-patch14)
  #   AESTHETIC_PYTHON         python with torch+transformers (default ComfyUI venv)
  #   AESTHETIC_GATE_SCRIPT    scoring script (default Rails bin/aesthetics_gate.py)
  #   AESTHETIC_THRESHOLD      reject when aesthetic score < threshold (default 4.5)
  #   SHARPNESS_THRESHOLD      reject when Laplacian variance < threshold (default 30.0)
  #   AESTHETIC_GATE_DISABLED=1   emergency bypass (accept everything)
  class RealismGate
    DEFAULT_MODEL_DIR = '/mnt/fscache/essdee/aesthetics-gate/aesthetics-predictor-v1-vit-large-patch14'
    DEFAULT_PYTHON    = '/mnt/fscache/essdee/ComfyUI/venv/bin/python'
    TIMEOUT_S = 120 # first call includes model load from disk

    Result = Struct.new(:safe, :aesthetic_score, :sharpness, :reason, :error, keyword_init: true)

    # @param image_path [String] absolute path to the rendered image
    # @return [Result] safe=false means "do NOT queue this image"
    def call(image_path:)
      return Result.new(safe: true) if disabled?

      unless File.file?(image_path)
        return Result.new(safe: false, error: "image missing: #{image_path}")
      end
      unless File.directory?(model_dir)
        return Result.new(safe: false, error: "aesthetic model dir missing: #{model_dir}")
      end

      out = run_scorer(image_path)
      Result.new(
        safe: out['decision'] == 'accept',
        aesthetic_score: out['aesthetic_score'],
        sharpness: out['sharpness'],
        reason: out['reason'],
        error: out['error']
      )
    rescue StandardError => e
      Result.new(safe: false, error: "#{e.class}: #{e.message}")
    end

    def model_dir
      ENV.fetch('AESTHETIC_MODEL_DIR', DEFAULT_MODEL_DIR)
    end

    def aesthetic_threshold
      ENV.fetch('AESTHETIC_THRESHOLD', '4.5').to_f
    end

    def sharpness_threshold
      ENV.fetch('SHARPNESS_THRESHOLD', '30.0').to_f
    end

    private

    def disabled?
      ENV['AESTHETIC_GATE_DISABLED'] == '1'
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