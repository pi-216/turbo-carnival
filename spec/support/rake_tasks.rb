# frozen_string_literal: true

# Rails.application.load_tasks is NOT idempotent for Rake task BODIES: loading the
# .rake files a second time APPENDS the same action to the existing task, so a task
# invoked from a spec runs its body once per load. Measured 2026-09-20: two spec
# files calling `Rails.application.load_tasks` in before(:all) made
# `scheduling:post_scheduled` publish TWO posts per invoke, which silently broke the
# release-pacing spec (it asserts that only the earliest due post goes out -- the
# second body run released the deferred post too). Nothing warned: the spec that
# broke was a different file from the one that caused it.
#
# Specs must load the tasks through this helper, which loads them exactly once per
# process. Any direct `Rails.application.load_tasks` in a spec reintroduces the
# duplication for every task in the suite.
module RakeTasksHelper
  @loaded = false

  class << self
    attr_accessor :loaded
  end

  def load_rake_tasks!
    return if RakeTasksHelper.loaded

    RakeTasksHelper.loaded = true
    Rails.application.load_tasks
  end
end

RSpec.configure do |config|
  config.include RakeTasksHelper
end
