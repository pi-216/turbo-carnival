# frozen_string_literal: true

class QualityAssessImage < ApplicationCommand
  requires :image_candidate

  returns :quality_score, :quality_metrics, :passed

  PYTHON_BIN = "/mnt/fscache/essdee/ComfyUI/.venv/bin/python"
  SCRIPT_PATH = Rails.root.join("scripts/assess_image_quality.py")
  DEFAULT_BLUR_THRESHOLD = ENV.fetch("QA_BLUR_THRESHOLD", 10).to_i

  def call
    path = context.image_candidate.image_path

    unless path && File.exist?(path.to_s)
      stop_and_fail!("Image file not found: #{path}")
      return
    end

    result = run_assessment(path)
    store_results(result)

    unless result[:passed]
      context.image_candidate.reject!
      Rails.logger.info(
        "QualityAssessImage: Candidate ##{context.image_candidate.id} rejected — " \
        "score=#{result[:quality_score]} issues=#{result[:issues]}"
      )
    end

    context.quality_score = result[:quality_score]
    context.quality_metrics = result.except(:passed, :path)
    context.passed = result[:passed]
  rescue StandardError => e
    # Don't block the pipeline on QA failures — log and pass
    Rails.logger.error("QualityAssessImage failed for candidate ##{context.image_candidate.id}: #{e.message}")
    context.quality_score = 50.0   # Neutral score on failure
    context.quality_metrics = { error: e.message }
    context.passed = true           # Don't reject on tool failure
  end

  private

  def run_assessment(path)
    cmd = [ PYTHON_BIN, SCRIPT_PATH.to_s, path.to_s, "--threshold", DEFAULT_BLUR_THRESHOLD.to_s ]
    stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      Rails.logger.warn("QA script exited #{status.exitstatus}: #{stderr.strip}")
    end

    result = JSON.parse(stdout, symbolize_names: true)
    result[:passed] = status.success? && result[:passed] != false
    result
  rescue JSON::ParserError => e
    Rails.logger.error("QA script returned invalid JSON: #{stdout&.slice(0, 200)}")
    { passed: true, quality_score: 50, issues: [ "JSON parse error" ], error: e.message }
  end

  def store_results(result)
    context.image_candidate.update!(
      quality_score: result[:quality_score],
      quality_metrics: result.slice(:blur_score, :contrast, :brightness, :width, :height, :issues)
    )
  end
end
