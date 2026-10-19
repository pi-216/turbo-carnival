# frozen_string_literal: true

module ContentStrategy
  class NoUnpostedPhotosError < StandardError
    def initialize(details = nil)
      message = "No unposted photos available"
      message += ": #{details}" if details
      super(message)
    end
  end
end
