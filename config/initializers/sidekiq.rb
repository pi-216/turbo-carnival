# frozen_string_literal: true

Sidekiq.configure_server do |config|
  # Use Redis DB 1 to isolate from crawlr (DB 0), t-chat (DB 2), etc.
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1') }

  config.on(:startup) do
    Rails.logger.info "Starting ComfyUI background workers..."
    JobPollerWorker.perform_async
    JobSubmitterWorker.perform_async
    # GPU-free abandoned-render recovery on its own 5-min loop: RenderSalvage's
    # only other driver is the growth tick's sync, which a tick that cannot
    # acquire the 4090 never reaches. See Growth::AbandonedRenderWorker.
    Growth::AbandonedRenderWorker.perform_async
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1') }
end
