# frozen_string_literal: true

require "gl_command"

# Base class for every mutation in the application.
#
# Usage contract (per the command pattern):
#   * Controllers parse input → call a Command → render from the Result.
#     They never mutate models directly ("no fat models").
#   * `.call` returns a GLCommand::Context (a Result): `.success?`,
#     `.error`, `.full_error_message`, plus declared `returns`. Never raise
#     domain errors to the view — read `full_error_message` instead.
#   * `.call!` raises on failure. Use it inside jobs, rake tasks, and when
#     composing a command from other commands (errors bubble up).
#   * Side effects (emails, background jobs, webhooks) MUST be scheduled via
#     +run_after_commit+, never inline inside +call+ — so a failed transaction
#     can't produce orphaned side effects.
#   * External writes (3rd-party APIs / webhooks) MUST carry an idempotency
#     key so a retried command never fires a side effect twice.
class ApplicationCommand < GLCommand::Callable
  # Runs +block+ only after the surrounding DB transaction commits. If there
  # is no open transaction (e.g. called outside one), runs immediately.
  def run_after_commit(&block)
    if ActiveRecord::Base.connection.transaction_open?
      ActiveRecord::Base.connection.current_transaction.after_commit(&block)
    else
      block.call
    end
  end
end
