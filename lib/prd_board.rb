# frozen_string_literal: true

require "json"

# Board-item resolution for bin/publish_prd.
#
# Board 2 auto-adds newly created issues to the project, which races the
# explicit `gh project item-add`: when the auto-add wins, GitHub answers
# "Content already exists in this project" and the publish aborted mid-tranche,
# leaving a silent partial publication. The already-exists answer is therefore a
# success path — the item id is resolved from the board instead of created.
module PrdBoard
  ALREADY_EXISTS = "already exists in this project"

  class Error < StandardError; end

  module_function

  # runner is a callable `->(*argv) { [output, success] }`. The gh invocation is
  # injected so both the create and the resolve branch are unit-testable
  # without network access.
  def add_or_resolve(issue_url, number:, project:, runner:)
    out, ok = runner.call(*item_add_args(issue_url, project))
    return item_id(out) if ok
    raise Error, out unless out.include?(ALREADY_EXISTS)

    item_id_for(number, project: project, runner: runner) ||
      raise(Error, "issue ##{number} is on the board but its item id could not be resolved")
  end

  # The board item id for an issue number, or nil when the issue is not on the
  # board (or its item carries no id).
  def item_id_for(number, project:, runner:)
    out, ok = runner.call(*item_list_args(project))
    raise Error, out unless ok

    items = parse(out).fetch("items", [])
    item = items.find { |candidate| candidate.dig("content", "number") == number }
    found = item&.dig("id").to_s
    found.empty? ? nil : found
  end

  def item_add_args(issue_url, project)
    [ "gh", "project", "item-add", project[:number].to_s, "--owner", project[:owner],
     "--url", issue_url, "--format", "json" ]
  end

  def item_list_args(project)
    [ "gh", "project", "item-list", project[:number].to_s, "--owner", project[:owner],
     "--limit", "500", "--format", "json" ]
  end

  def item_id(out)
    id = parse(out)["id"].to_s
    raise Error, "gh returned no project item id (#{out})" if id.empty?

    id
  end

  def parse(out)
    JSON.parse(out)
  rescue JSON::ParserError => e
    raise Error, "unparseable gh output (#{e.message})"
  end
end
