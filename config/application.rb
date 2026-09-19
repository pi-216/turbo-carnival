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
    config.autoload_lib(ignore: %w[assets tasks])

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
    config.hosts << '.pi216.ai' unless Rails.env.test?
    
    # Configure session store
    config.session_store :cookie_store, key: '_turbo_carnival_session'
  end
end
