# frozen_string_literal: true

# Applies this repo's database triggers to the TEST database before the suite runs.
#
# WHY THIS IS NECESSARY. The schema format here is Rails' default `:ruby`, and `db/schema.rb`
# cannot carry a trigger -- so `db:test:prepare` (which is what CI runs) builds a database
# WITHOUT them. A spec that asserts a trigger refuses a write would then pass against a guard
# that was not there, which is worse than no spec at all: it is a green light on nothing.
#
# The SQL is read from `db/triggers/`, the same files the migrations apply, so there is one
# source of truth and no drift. Applying them here is also what makes the test database match a
# migrated one, so a spec exercises the real constraint rather than a Ruby imitation of it.
module DbTriggers
  DIR = Rails.root.join("db", "triggers")

  def self.files
    Dir[DIR.join("*.sql")].sort
  end

  # Idempotent by construction: the files use CREATE OR REPLACE and DROP TRIGGER IF EXISTS.
  def self.apply_all!
    files.each { |file| ActiveRecord::Base.connection.execute(File.read(file)) }
  end
end

RSpec.configure do |config|
  config.before(:suite) { DbTriggers.apply_all! }
end
