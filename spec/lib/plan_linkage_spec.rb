require "rails_helper"
require "tmpdir"
require_relative "../../lib/plan_linkage"

# Guard for PRD 0003 W1.3 / ticket #48.
#
# The plan's linkage contract (docs/PROJECT_PLAN.md §4/§5) says the §7 index is
# generated from the board and `rake plan:check` fails on divergence. These
# specs are the enforcement line for that contract: they prove the field
# extraction against every linkage shape that exists on the board, each of
# the four check conditions, the index rendering, and — per the ticket's
# success criteria — that a fabricated plan id fails, a seeded cycle fails
# (then reverts), and hand edits to the generated index are overwritten,
# not preserved.

RSpec.describe PlanLinkage do
  # Mirrors the §7 tables of docs/PROJECT_PLAN.md: the W1 and W2 items with
  # their PRD column. State cells are hand-typed on purpose — the point of
  # the contract is that the board overwrites them.
  PLAN_DOC = <<~MD
    # Project plan

    ## 7. Items

    ### W1 — core-infrastructure

    <!-- plan:index:start W1 -->
    | id | item | PRD | state |
    |---|---|---|---|
    | **W1.1** | local brain | `docs/prd/0001-…` | hand-typed state |
    | W1.2 | config spine | `docs/prd/0002-…` | hand-typed state |
    | W1.3 | repo conventions | `docs/prd/0003-…` | hand-typed state |
    | W1.4 | harness conformance | `docs/prd/0006-…` | hand-typed state |
    | W1.5 | safety posture | `docs/prd/0007-…` | hand-typed state |
    <!-- plan:index:end W1 -->

    - **W1.1** — rationale prose survives regeneration.

    ### W2 — experiment

    <!-- plan:index:start W2 -->
    | id | item | PRD | state |
    |---|---|---|---|
    | W2.1 | the lane | `docs/prd/0004-…` | spec written 2026-10-19 |
    | — | render-axis experiment, parked | *its own PRD required* | un-run; keep/drop is the founder's call |
    <!-- plan:index:end W2 -->
  MD

  def plan_doc
    PlanLinkage::PlanDoc.parse(PLAN_DOC)
  end

  def item(number:, title: "[W1.1] do a thing", status: "Todo", body: nil, labels: [ "ticket" ], track: "core-infrastructure")
    { number: number, title: title, status: status, body: body, labels: labels, track: track }
  end

  def board_json(*items)
    payload = items.map do |it|
      {
        "id" => "PVTI_#{it[:number]}",
        "content" => { "number" => it[:number], "title" => it[:title], "body" => it[:body] },
        "status" => it[:status],
        "track" => it[:track],
        "labels" => it[:labels]
      }
    end
    { "items" => payload, "totalCount" => payload.size }.to_json
  end

  def board(*items)
    PlanLinkage::Board.from_json(board_json(*items))
  end

  # Replaces the state cells of the given item ids in a copy of the fixture.
  def doc_with_cells(cells)
    PLAN_DOC.lines.map do |line|
      m = line.match(/^\|\s*\**\s*(W\d+\.\d+)\s*\**\s*\|/)
      next line unless m && cells.key?(m[1])

      parts = line.strip.sub(/\A\|/, "").sub(/\|\s*\z/, "").split("|")
      parts[3] = " #{cells[m[1]]} "
      "| #{parts.join(" | ")} |\n"
    end.join
  end

  def empty_board_states
    { "W1.1" => "no tickets yet", "W1.2" => "no tickets yet", "W1.3" => "no tickets yet", "W1.4" => "no tickets yet",
      "W1.5" => "no tickets yet", "W2.1" => "no tickets yet" }
  end

  describe ".field extraction" do
    it "reads the fenced ## Linkage block (the #45 shape)" do
      body = <<~B
        ## Linkage

        ```
        Plan        : docs/PROJECT_PLAN.md#w13-repo-conventions
        PRD         : docs/prd/0003-repo-conventions-and-a-verifiable-done.md
        Track       : core-infrastructure
        Role        : script-worker
        Depends on  : #45, #46
        Blocks      : #50
        Serves      : the plan's linkage contract stops being a habit
        ```
      B
      it = board(item(number: 45, title: "CI runs the real suite", body: body)).items.first

      expect(it.field("plan")).to eq("docs/PROJECT_PLAN.md#w13-repo-conventions")
      expect(it.field("prd")).to eq("docs/prd/0003-repo-conventions-and-a-verifiable-done.md")
      expect(it.field("depends")).to eq("#45, #46")
      expect(it.depends_on).to eq([ 45, 46 ])
      expect(it.blocks).to eq([ 50 ])
      expect(it.item_id(plan_doc)).to eq("W1.3")
    end

    it "reads leading lines with empty values (the #76 shape)" do
      body = <<~B
        Plan       : docs/PROJECT_PLAN.md#w14-harness-conformance-to-rails-venture-template
        PRD        : docs/prd/0006-harness-conformance-to-rails-venture-template.md
        Track      : core-infrastructure
        Role       : agent-worker
        Depends on :
        Blocks     :
        Serves     : a mutation contract that is implemented, not just described
      B
      it = board(item(number: 76, title: "Harness conformance: single lint entry point", body: body)).items.first

      expect(it.field("plan")).to eq("docs/PROJECT_PLAN.md#w14-harness-conformance-to-rails-venture-template")
      expect(it.depends_on).to eq([])
      expect(it.blocks).to eq([])
      expect(it.item_id(plan_doc)).to eq("W1.4")
    end

    it "reads the inline one-line ·-separated form (the #104 shape)" do
      body = <<~B
        **Goal.** The NSFW ViT gate stops rejecting and purging.

        **Linkage.** Parent: #113 · Plan: `docs/PROJECT_PLAN.md#w1--core-infrastructure` (W1) · PRD: `docs/prd/0007-safety-posture-reduction.md` · Track: `core-infrastructure` · Depends: `_ready_` · Blocks: tier pre-flight (A5) — the NSFW score is a pre-flight input.
      B
      it = board(item(number: 104, title: "The NSFW gate is a measurement, not a veto", body: body)).items.first

      expect(it.field("plan")).to eq("docs/PROJECT_PLAN.md#w1--core-infrastructure (W1)")
      expect(it.field("prd")).to eq("docs/prd/0007-safety-posture-reduction.md")
      expect(it.depends_on).to eq([])
      expect(it.blocks).to eq([])
      expect(it.item_id(plan_doc)).to eq("W1.5")
    end

    it "treats every none token as no dependency, including trailing prose" do
      bodies = {
        "_ready_" => [],
        "nothing" => [],
        "_nothing_" => [],
        "_nothing_ (it unparks the render-axis experiment)" => [],
        "" => []
      }
      bodies.each do |value, expected|
        it = board(item(number: 1, body: "Depends on  : #{value}\n")).items.first
        expect(it.depends_on).to eq(expected)
      end
    end

    it "reads dependencies and blocks as issue numbers" do
      it = board(item(number: 50, body: "Depends on : #45, #46, #47, #48\nBlocks     : _nothing_\n")).items.first

      expect(it.depends_on).to eq([ 45, 46, 47, 48 ])
      expect(it.blocks).to eq([])
    end
  end

  describe "plan id resolution" do
    it "resolves the title prefix first (the §4 join key), even over a conflicting Plan: anchor" do
      it = board(item(number: 48, title: "[W1.3] plan:index and plan:check as rake tasks", body: "Plan : docs/PROJECT_PLAN.md#w99-fabricated\n")).items.first

      expect(it.item_id(plan_doc)).to eq("W1.3")
    end

    it "resolves an item-level anchor on the Plan: line when the title has no prefix" do
      it = board(item(number: 45, title: "CI runs the real suite", body: "Plan : docs/PROJECT_PLAN.md#w13-repo-conventions\n")).items.first

      expect(it.item_id(plan_doc)).to eq("W1.3")
    end

    it "resolves a workstream-level anchor through the PRD (the #103 shape)" do
      body = <<~B
        Plan        : docs/PROJECT_PLAN.md#w1--core-infrastructure
        PRD         : docs/prd/0007-safety-posture-reduction.md
      B
      it = board(item(number: 103, title: "Vision reads served from the brain server", body: body)).items.first

      expect(it.item_id(plan_doc)).to eq("W1.5")
    end

    it "resolves through the prd:NNNN label when nothing else is cited" do
      it = board(item(number: 112, title: "Index hygiene + stale posture-wording sweep (PRD 0007 C)", body: nil, labels: [ "ticket", "prd:0007" ])).items.first

      expect(it.item_id(plan_doc)).to eq("W1.5")
    end

    it "resolves an epic's prose citation (the #36 shape)" do
      body = "Product epic for PRD 0002. Plan item **W1.2** (core-infrastructure)."
      it = board(item(number: 36, title: "[PRD] PRD 0002 — Versioned content config", body: body, status: "In Progress")).items.first

      expect(it.item_id(plan_doc)).to eq("W1.2")
    end

    it "resolves an epic by the PRD number in its title when the prose is bare (the #75 shape)" do
      it = board(item(number: 75, title: "[PRD] PRD 0006 — Harness conformance to rails-venture-template", body: "Product epic for PRD 0006.", status: "In Progress")).items.first

      expect(it.item_id(plan_doc)).to eq("W1.4")
    end

    it "returns nil when nothing cites a plan" do
      it = board(item(number: 121, title: "[pipeline] Mechanize the PRD parent-ticket edge", body: "## Symptom\n\nhand-cut edges.\n")).items.first

      expect(it.item_id(plan_doc)).to be_nil
    end
  end

  describe "condition a — open items must cite a plan id" do
    it "fails an open item that cites nothing" do
      b = board(item(number: 121, title: "[pipeline] Mechanize the PRD parent-ticket edge", body: "## Symptom\n\nhand-cut edges.\n"))
      violations = PlanLinkage::Check.new(board: b, plan: plan_doc).violations.select { |v| v.kind == "no-plan-id" }

      expect(violations.map(&:message)).to include(match(/#121/))
    end

    it "does not fail a Done item that cites nothing" do
      b = board(item(number: 19, title: "Add repo-owned bin/rspec", body: nil, status: "Done", labels: []))
      violations = PlanLinkage::Check.new(board: b, plan: plan_doc).violations.select { |v| v.kind == "no-plan-id" }

      expect(violations).to be_empty
    end

    it "fails a ticket that cites a fabricated plan id (success criterion)" do
      b = board(item(number: 99, title: "[W9.9] fabricate a plan id", body: "Plan : docs/PROJECT_PLAN.md#w99-fabricated\n"))
      violations = PlanLinkage::Check.new(board: b, plan: plan_doc).violations.select { |v| v.kind == "unknown-plan-id" }

      expect(violations.map(&:message)).to include(match(/#99.*W9\.9/))
    end
  end

  describe "condition c — dependency cycles" do
    it "fails a two-ticket cycle seeded via Depends on, and passes once reverted" do
      a = item(number: 1, title: "[W1.1] a", body: "Depends on : #2\n")
      b = item(number: 2, title: "[W1.1] b", body: "Depends on : #1\n")
      violations = PlanLinkage::Check.new(board: board(a, b), plan: plan_doc).violations.select { |v| v.kind == "dependency-cycle" }

      expect(violations).not_to be_empty
      expect(violations.first.message).to match(/#1.*#2.*#1| #1 /)

      reverted = item(number: 2, title: "[W1.1] b", body: "Depends on : _ready_\n")
      expect(PlanLinkage::Check.new(board: board(a, reverted), plan: plan_doc).violations.select { |v| v.kind == "dependency-cycle" }).to be_empty
    end

    it "fails a three-ticket cycle" do
      violations = PlanLinkage::Check.new(
        board: board(
          item(number: 1, body: "Depends on : #3\n"),
          item(number: 2, body: "Depends on : #1\n"),
          item(number: 3, body: "Depends on : #2\n")
        ),
        plan: plan_doc
      ).violations.select { |v| v.kind == "dependency-cycle" }

      expect(violations).not_to be_empty
    end

    it "does not report a consistent Depends on / Blocks pair as a cycle" do
      violations = PlanLinkage::Check.new(
        board: board(
          item(number: 45, body: "Blocks : #47\n"),
          item(number: 47, body: "Depends on : #45\n")
        ),
        plan: plan_doc
      ).violations.select { |v| v.kind == "dependency-cycle" }

      expect(violations).to be_empty
    end
  end

  describe "condition d — In Progress with an unmet Depends on" do
    it "fails an In Progress ticket whose dependency is not Done" do
      b = board(
        item(number: 47, title: "[W1.3] the gate", status: "In Progress", body: "Depends on : #45\n"),
        item(number: 45, title: "[W1.3] the suite", status: "Todo", body: "Depends on : _ready_\n")
      )

      expect(PlanLinkage::Check.new(board: b, plan: plan_doc).violations.map(&:kind)).to include("unmet-dependency")
    end

    it "passes when the dependency is Done" do
      b = board(
        item(number: 47, status: "In Progress", body: "Depends on : #45\n"),
        item(number: 45, status: "Done", body: "Depends on : _ready_\n")
      )

      expect(PlanLinkage::Check.new(board: b, plan: plan_doc).violations.select { |v| v.kind == "unmet-dependency" }).to be_empty
    end

    it "fails when the dependency is not on the board at all" do
      b = board(item(number: 47, status: "In Progress", body: "Depends on : #999\n"))

      expect(PlanLinkage::Check.new(board: b, plan: plan_doc).violations.map { |v| v.message }.join("\n")).to match(/#999/)
    end

    it "does not fail a Todo ticket with an open dependency" do
      b = board(
        item(number: 47, status: "Todo", body: "Depends on : #45\n"),
        item(number: 45, status: "Todo", body: "Depends on : _ready_\n")
      )

      expect(PlanLinkage::Check.new(board: b, plan: plan_doc).violations.select { |v| v.kind == "unmet-dependency" }).to be_empty
    end
  end

  describe "condition b — the generated index matches the board" do
    it "passes when every cell matches the board facts" do
      b = board(
        item(number: 22, title: "[W1.1] a", status: "Done", body: "Depends on : _ready_\n"),
        item(number: 23, title: "[W1.1] b", status: "Done", body: "Depends on : _ready_\n"),
        item(number: 20, title: "[PRD] PRD 0001 — epic", status: "Done", body: "Product epic for PRD 0001. Plan item **W1.1** (core-infrastructure).")
      )
      cells = empty_board_states.merge("W1.1" => "**done** · epic #20 · tickets #22–#23")

      expect(PlanLinkage::Check.new(board: b, plan: PlanLinkage::PlanDoc.parse(doc_with_cells(cells))).violations.select { |v| v.kind == "stale-index" }).to be_empty
    end

    it "fails a cell that cites a closed issue as open (success-criterion direction)" do
      b = board(
        item(number: 22, title: "[W1.1] a", status: "Done", body: "Depends on : _ready_\n"),
        item(number: 23, title: "[W1.1] b", status: "Todo", body: "Depends on : _ready_\n")
      )
      # The PLAN_DOC fixture carries hand-typed cells, so W1.1 is stale against this board.
      expect(PlanLinkage::Check.new(board: b, plan: plan_doc).violations.map { |v| v.message }.join("\n")).to match(/W1\.1/)
    end
  end

  describe "state cell rendering" do
    it "renders done, with epic and compact ticket ranges" do
      b = board(
        item(number: 36, title: "[PRD] PRD 0002 — epic", status: "Done", body: "Product epic for PRD 0002. Plan item **W1.2**"),
        item(number: 37, title: "[W1.2] a", status: "Done"),
        item(number: 38, title: "[W1.2] b", status: "Done"),
        item(number: 39, title: "[W1.2] c", status: "Done")
      )

      expect(PlanLinkage.state_cell(b, plan_doc, "W1.2")).to eq("**done** · epic #36 · tickets #37–#39")
    end

    it "renders open with a done count and mixed ranges" do
      b = board(
        item(number: 40, title: "[W1.2] a", status: "Todo"),
        item(number: 41, title: "[W1.2] b", status: "Done"),
        item(number: 42, title: "[W1.2] c", status: "Todo"),
        item(number: 73, title: "[W1.2] d", status: "Todo")
      )

      expect(PlanLinkage.state_cell(b, plan_doc, "W1.2")).to eq("**open** · tickets #40–#42, #73 · 1/4 done")
    end

    it "renders no tickets yet" do
      expect(PlanLinkage.state_cell(board, plan_doc, "W2.1")).to eq("no tickets yet")
    end

    it "compresses consecutive runs and lists singletons" do
      b = board(
        item(number: 22, title: "[W1.1] a", status: "Done"),
        item(number: 23, title: "[W1.1] b", status: "Done"),
        item(number: 64, title: "[W1.1] c", status: "Done")
      )

      expect(PlanLinkage.state_cell(b, plan_doc, "W1.1")).to eq("**done** · tickets #22–#23, #64")
    end
  end

  describe "plan:index rewrite" do
    around do |example|
      @tmp = Dir.mktmpdir("plan-linkage")
      @path = File.join(@tmp, "PROJECT_PLAN.md")
      example.run
    ensure
      FileUtils.remove_entry(@tmp) if @tmp
    end

    def write_doc(text = PLAN_DOC)
      File.write(@path, text)
    end

    def index_for(b)
      PlanLinkage::Index.new(board: b, plan: PlanLinkage::PlanDoc.parse(File.read(@path)), plan_path: @path)
    end

    it "overwrites hand edits to the generated cell, not the rest of the document (success criterion)" do
      b = board(item(number: 22, title: "[W1.1] a", status: "Done"))
      hand_edited = PLAN_DOC.sub("hand-typed state", "hand-edited by a human")
      write_doc(hand_edited)

      changed = index_for(b).rewrite!

      expect(File.read(@path)).not_to include("hand-edited by a human")
      expect(File.read(@path)).to include("| **W1.1** | local brain | `docs/prd/0001-…` | **done** · tickets #22 |")
      expect(File.read(@path)).to include("rationale prose survives regeneration")
      expect(changed.map(&:id)).to include("W1.1")
    end

    it "preserves rows without a plan id and leaves matching cells untouched" do
      b = board(item(number: 22, title: "[W1.1] a", status: "Done"))
      write_doc(doc_with_cells(empty_board_states.merge("W1.1" => "**done** · tickets #22")))

      changed = index_for(b).rewrite!

      expect(changed).to be_empty
      expect(File.read(@path)).to include("un-run; keep/drop is the founder's call")
    end
  end

  describe "Board.read" do
    it "parses a gh item-list payload through an injected runner" do
      payload = board_json(item(number: 22, status: "Done"))
      runner = ->(_cmd) { payload }

      b = PlanLinkage::Board.read(runner: runner)

      expect(b.items.map(&:number)).to eq([ 22 ])
      expect(b.items.first.done?).to be(true)
      expect(b[22].status).to eq("Done")
    end

    it "raises ReadError on a non-zero runner (fail-closed)" do
      runner = ->(_cmd) { raise PlanLinkage::ReadError, "gh not authenticated" }

      expect { PlanLinkage::Board.read(runner: runner) }.to raise_error(PlanLinkage::ReadError)
    end

    it "raises ReadError on a payload that fills the page limit (silently missing items are worse than a failure)" do
      payload = board_json(
        item(number: 1, title: "[W1.1] a"),
        item(number: 2, title: "[W1.1] b"),
        item(number: 3, title: "[W1.1] c")
      )
      runner = ->(_cmd) { payload }

      expect { PlanLinkage::Board.read(runner: runner, limit: 2) }.to raise_error(PlanLinkage::ReadError, /limit/)
    end
  end

  describe "PlanDoc parsing" do
    it "collects item ids, workstream ids and the PRD-to-item map from §7 tables" do
      doc = plan_doc

      expect(doc.item_ids).to contain_exactly("W1.1", "W1.2", "W1.3", "W1.4", "W1.5", "W2.1")
      expect(doc.workstream_ids).to contain_exactly("W1", "W2")
      expect(doc.prd_map).to eq({ "0001" => "W1.1", "0002" => "W1.2", "0003" => "W1.3", "0004" => "W2.1", "0006" => "W1.4", "0007" => "W1.5" })
    end

    it "finds the marked sections and their rows" do
      doc = plan_doc

      expect(doc.sections.keys).to contain_exactly("W1", "W2")
      expect(doc.sections["W1"].rows.map(&:id)).to eq([ "W1.1", "W1.2", "W1.3", "W1.4", "W1.5" ])
      expect(doc.sections["W2"].rows.map(&:id)).to eq([ "W2.1", nil ])
      expect(doc.sections["W1"].rows.first.state).to eq("hand-typed state")
    end
  end
end
