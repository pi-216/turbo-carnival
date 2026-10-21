# frozen_string_literal: true

require_relative "../plan_linkage"

# The plan's linkage contract, as tasks (PRD 0003 W1.3 / ticket #48).
#
# docs/PROJECT_PLAN.md §5: the §7 index is generated from the board, never
# typed, and `plan:check` is the only mechanism that notices when the board
# and the plan have diverged. Both tasks read the board with ONE REST call
# (no GraphQL budget) and are pure stdlib — no Rails environment, no DB.

namespace :plan do
  desc "Fail on plan/board drift: an open item citing no plan id (or a fabricated one), a stale index cell, a dependency cycle, or an In Progress ticket with a not-Done Depends on"
  task :check do
    board = PlanLinkage::Board.read
    plan  = PlanLinkage::PlanDoc.parse(File.read(PlanLinkage.plan_path))
    violations = PlanLinkage::Check.new(board: board, plan: plan).violations

    if violations.empty?
      puts "PLAN OK — #{board.items.size} board items, no drift against #{PlanLinkage.plan_path}"
    else
      violations.each { |v| puts "  [#{v.kind}] #{v.message}" }
      puts "PLAN FAIL — #{violations.size} violation(s); fix the drift or run rake plan:index"
      exit 1
    end
  end

  desc "Regenerate the marked §7 index state column from the board; a hand edit there is overwritten, not preserved"
  task :index do
    board = PlanLinkage::Board.read
    plan  = PlanLinkage::PlanDoc.parse(File.read(PlanLinkage.plan_path))
    changed = PlanLinkage::Index.new(board: board, plan: plan, plan_path: PlanLinkage.plan_path).rewrite!

    if changed.empty?
      puts "plan:index — index already matches the board (0 cells changed)"
    else
      changed.each { |row| puts "  #{row.id}: #{row.before}  =>  #{row.after}" }
      puts "plan:index — #{changed.size} cell(s) rewritten from the board"
    end
  end
end
