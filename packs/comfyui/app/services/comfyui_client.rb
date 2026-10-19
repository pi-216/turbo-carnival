class ComfyuiClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class APIError < Error; end

  def initialize(base_url: nil)
    @base_url = base_url || Rails.application.config.comfyui.base_url
  end

  # True when a job failed purely because the GPU ran out of memory.
  # OOM is retryable: the workflow is memory-tight on shared GPUs and usually
  # succeeds on a subsequent (warmer) run. Not a logic defect.
  def self.oom_error?(message)
    msg = message.to_s.downcase
    msg.include?("out of memory") || msg.include?("would exceed allowed memory")
  end

  def submit_workflow(workflow_json)
    response = connection.post("/prompt") do |req|
      req.body = { prompt: workflow_json }.to_json
      req.headers["Content-Type"] = "application/json"
    end

    result = parse_response(response)
    # ComfyUI returns prompt_id, we normalize to job_id for our API
    { job_id: result[:prompt_id], prompt_number: result[:number] }
  rescue Faraday::Error => e
    raise ConnectionError, "Failed to connect to ComfyUI: #{e.message}"
  end

  def get_job_status(job_id)
    response = connection.get("/history/#{job_id}")
    history = parse_response(response)

    # History returns a hash with prompt_id as key
    job_data = history[job_id.to_sym] || history[job_id.to_s]

    return { status: "not_found" } unless job_data

    status = job_data.dig(:status, :status_str)
    completed = job_data.dig(:status, :completed)
    outputs = job_data[:outputs]

    case status
    when "success"
      { status: "completed", output: outputs }
    when "error"
      error_messages = job_data.dig(:status, :messages)&.select { |m| m[0] == "execution_error" }
      { status: "failed", error: error_messages&.first&.dig(1, :exception_message) || "Unknown error" }
    else
      if completed
        { status: "completed", output: outputs }
      else
        { status: "running" }
      end
    end
  rescue Faraday::Error => e
    raise ConnectionError, "Failed to get job status: #{e.message}"
  end

  def download_image(image_url)
    response = connection.get(image_url)

    if response.success?
      response.body
    else
      raise APIError, "Failed to download image: HTTP #{response.status}"
    end
  rescue Faraday::Error => e
    raise ConnectionError, "Failed to download image: #{e.message}"
  end

  private

  def connection
    @connection ||= Faraday.new(url: @base_url) do |f|
      f.request :json
      f.request :retry, max: 3, interval: 0.5, backoff_factor: 2
      f.response :json, content_type: /\bjson$/
      f.adapter Faraday.default_adapter
      f.options.timeout = Rails.application.config.comfyui.timeout
    end
  end

  def parse_response(response)
    if response.success?
      response.body.is_a?(Hash) ? response.body.deep_symbolize_keys : response.body
    else
      raise APIError, "ComfyUI API error: HTTP #{response.status}"
    end
  end
end
