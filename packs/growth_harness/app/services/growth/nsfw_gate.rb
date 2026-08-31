# frozen_string_literal: true

module Growth
  # Third-party NSFW gate (Falconsai/nsfw_image_detection, ViT-base via
  # ComfyUI's venv torch, CPU-only) — blocks a freshly rendered image from
  # entering the queue. Fail-closed: any error rejects the image.
  #
  # Env knobs (read at call time so they're runtime-tunable):
  #   NSFW_MODEL_DIR    model path (default /mnt/nas-ai-models/gates/nsfw_image_detection)
  #   NSFW_PYTHON       python with torch+transformers (default ComfyUI venv)
  #   NSFW_GATE_SCRIPT  classifier script (default Rails bin/nsfw_gate.py)
  #   NSFW_THRESHOLD    reject when nsfw prob >= threshold (default 0.5)
  #   NSFW_GATE_DISABLED=1  emergency bypass (accept everything)
  class NsfwGate
    DEFAULT_MODEL_DIR = '/mnt/nas-ai-models/gates/nsfw_image_detection'
    DEFAULT_PYTHON    = '/mnt/fscache/essdee/ComfyUI/venv/bin/python'
    TIMEOUT_S = 90 # first call includes model load from disk

    Result = Struct.new(:safe, :label, :nsfw_score, :error, keyword_init: true)

    # @param image_path [String] absolute path to the rendered image
    # @return [Result] safe=false means "do NOT queue this image"
    def call(image_path:)
      return Result.new(safe: true) if disabled?

      unless File.file?(image_path)
        return Result.new(safe: false, error: "image missing: #{image_path}")
      end
      unless File.directory?(model_dir)
        return Result.new(safe: false, error: "nsfw model dir missing: #{model_dir}")
      end

      out = run_classifier(image_path)
      Result.new(
        safe: out['decision'] == 'accept',
        label: out['label'],
        nsfw_score: out['nsfw_score'].to_f,
        error: out['error']
      )
    rescue StandardError => e
      Result.new(safe: false, error: "#{e.class}: #{e.message}")
    end

    def model_dir
      ENV.fetch('NSFW_MODEL_DIR', DEFAULT_MODEL_DIR)
    end

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