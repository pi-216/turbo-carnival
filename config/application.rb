require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TurboCarnival
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # `lib/ai` is deliberately NOT a Zeitwerk root: its files define the
    # `AI::` namespace, while the directory name leads Zeitwerk to expect
    # `Ai::` -- so `lib/ai/gemini_client.rb` was reported as not defining
    # `Ai::GeminiClient` and eager loading ABORTED (`zeitwerk:check` failed in
    # every env, and `RAILS_ENV=production` could not boot the app at all; the
    # running service hid it because bin/run_server.sh pins RAILS_ENV=development,
    # which does not eager load). Every call site already loads these files
    # explicitly (`load 'lib/ai/ollama_client.rb'`, `require Rails.root.join(...)`),
    # so ignoring the directory is the accurate declaration, not a workaround.
    #
    # `lib/rspec` is deliberately NOT a Zeitwerk root either: the agent
    # test-signal formatter registers itself in the class body
    # (`RSpec::Core::Formatters.register ...`), but rspec-core is not loaded
    # when the app boots. The test env sets `eager_load = ENV["CI"].present?`,
    # so on a CI runner Zeitwerk eagerly loaded the file at boot, hit the
    # missing `RSpec` constant, and ABORTED app boot — every spec file then
    # failed to load (`NameError: uninitialized constant Rspec::AgentFormatter`,
    # 114/114 files). bin/rspec loads the file by explicit path, so ignoring
    # the directory is the accurate declaration, not a workaround.
    config.autoload_lib(ignore: %w[assets tasks ai rspec])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = false

    # Allow the Cloudflare-tunnel host used to serve media to Instagram.
    # Test-only guard: in the test environment this append turns Rails' permissive
    # default into a one-entry allowlist, so every request spec that uses the
    # default host (www.example.com) is rejected with 403 by
    # ActionDispatch::HostAuthorization before it reaches the app -- which silently
    # disabled the whole request-spec suite (7 failures in
    # spec/requests/scheduling_posts_spec.rb). Production behaviour is unchanged.
    config.hosts << ".pi216.ai" unless Rails.env.test?

    # Configure session store
    config.session_store :cookie_store, key: "_turbo_carnival_session"

    # Single job substrate: Sidekiq (PRD 0006 Q5 / ticket #85). Set once here so
    # every environment enqueues on Sidekiq; no environment file overrides it.
    config.active_job.queue_adapter = :sidekiq
  end
end
