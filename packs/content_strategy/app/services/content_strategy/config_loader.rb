# frozen_string_literal: true

module ContentStrategy
  class ConfigLoader
    class << self
      def config
        @config ||= load_config
      end

      def get(key, default: nil)
        config[key.to_s] || default
      end

      def posting_frequency_min
        get('posting_frequency_min', default: 3)
      end

      def posting_frequency_max
        get('posting_frequency_max', default: 5)
      end

      def posting_days_gap
        get('posting_days_gap', default: 1)
      end

      def optimal_time_start_hour
        get('optimal_time_start_hour', default: 5)
      end

      def optimal_time_end_hour
        get('optimal_time_end_hour', default: 8)
      end

      def alternative_time_start_hour
        get('alternative_time_start_hour', default: 10)
      end

      def alternative_time_end_hour
        get('alternative_time_end_hour', default: 15)
      end

      def variety_min_days_gap
        get('variety_min_days_gap', default: 2)
      end

      def variety_max_same_cluster
        get('variety_max_same_cluster', default: 3)
      end

      def hashtag_count_min
        get('hashtag_count_min', default: 5)
      end

      def hashtag_count_max
        get('hashtag_count_max', default: 12)
      end

      def default_strategy
        get('default_strategy', default: 'thematic_rotation_strategy')
      end

      def reload!
        @config = load_config
      end

      private

      def load_config
        config_path = Rails.root.join('config', 'content_strategy.yml')
        yaml_config = YAML.load_file(config_path)
        env_config = yaml_config[Rails.env] || yaml_config['development']

        validate_config!(env_config)
        env_config
      end

      def validate_config!(config)
        required_keys = %w[
          posting_frequency_min posting_frequency_max posting_days_gap
          optimal_time_start_hour optimal_time_end_hour
          variety_min_days_gap variety_max_same_cluster
          hashtag_count_min hashtag_count_max
          default_strategy
        ]

        missing_keys = required_keys - config.keys
        raise "Missing required configuration keys: #{missing_keys.join(', ')}" if missing_keys.any?
      end
    end
  end
end
