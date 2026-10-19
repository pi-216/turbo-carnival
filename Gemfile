source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.0"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"

# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Load environment variables from .env file
  gem "dotenv-rails"

  # Testing framework
  gem "rspec-rails", "~> 8.0"
  gem "factory_bot_rails", "~> 6.4"
  gem "shoulda-matchers", "~> 6.0"
  gem "faker", "~> 3.2"
  gem "climate_control", "~> 1.2"
end

# Packs for modular Rails architecture
gem "packs-rails"

# State machines for model state management
gem "state_machines-activerecord", "~> 0.9"

# GLCommand for business logic command pattern
gem "gl_command", "~> 1.4"

# Observability pillar (PRD 0006 R7). These already arrive transitively via
# gl_exception_notifier <- gl_command, which is exactly why they were never visible as a
# rail: a transitive pull is not a dependency, and `GLExceptionNotifier` was calling an
# uninitialized `Sentry` (a silent no-op) for as long as the app has existed.
gem "sentry-rails"
gem "sentry-ruby"
gem "sentry-sidekiq"

# HTTP client for ComfyUI API
gem "faraday", "~> 2.9"
gem "faraday-retry", "~> 2.2"

# Background jobs
gem "sidekiq", "~> 7.0"

# Hotwire for SPA-like features
gem "turbo-rails"
gem "stimulus-rails"
gem "importmap-rails"

# ViewComponent for reusable UI components
gem "view_component"

# Tailwind CSS for styling
gem "tailwindcss-rails"

# Lookbook for component development and documentation
gem "lookbook", group: :development

gem "aws-sdk-s3", "~> 1.206"
gem "kaminari"
