# frozen_string_literal: true

#
# lib/plan_linkage.rb — the plan's linkage contract, as a check (PRD 0003 W1.3 / ticket #48).
#
# docs/PROJECT_PLAN.md §5 says two things make the plan true rather than a wish:
#
#   1. The §7 index is generated from the board, never typed. Item → tickets →
#      status is a query. `plan:index` rewrites the state column of each marked
#      §7 table; a hand edit there is overwritten, not preserved.
#   2. `plan:check` fails on:
#        a. an open board item citing no plan id (or a fabricated one);
#        b. a stale index cell — a closed issue cited as open;
#        c. a dependency cycle;
#        d. a ticket that is In Progress while a `Depends on` target is not Done.
#
# The board is read with ONE `gh project item-list` call (REST — no GraphQL
# budget burn): number, title, body, Status, Track, labels. That is the whole
# read surface; the check never parses screenshots or prose outside the
# linkage fields below.
#
# Plan id resolution (first hit wins):
#   1. the `[W1.1]` title prefix — the §4 join key;
#   2. an item-level anchor on the Plan: line (`#w13-repo-conventions` → W1.3);
#   3. the PRD file/number → the §7 table's PRD column;
#   4. the epic prose citation (`Plan item **W1.2**`);
#   5. the prd:NNNN label → the §7 table's PRD column.
#
# A workstream-level anchor (`#w1--core-infrastructure` → W1) is NOT an item
# id — resolution continues down the chain; it only counts as a citation for
# condition (a).

require "json"
require "set"
require "open3"

module PlanLinkage
  class ReadError < StandardError; end

  # The plan document, overridable for tests.
  def self.plan_path
    ENV["PLAN_DOC"] || File.join(Dir.pwd, "docs", "PROJECT_PLAN.md")
  end

  # A linkage value that means "none" — including the trailing-prose form the
  # board actually carries ("_nothing_ (it unparks the render-axis experiment)").
  NONE_TOKEN = /\A(?:_ready_|ready|nothing|_nothing_|none|—|-)[ \t]*(?:\(.*\))?\z/i

  LINKAGE_KEYS = {
    "plan" => /Plan/,
    "prd" => /PRD/,
    "track" => /Track/,
    "role" => /Role/,
    "depends" => /Depends(?:\s+on)?/,
    "blocks" => /Blocks/,
    "serves" => /Serves/
  }.freeze

  class Item
    attr_reader :number, :title, :body, :status, :track, :labels

    def initialize(number:, title:, body:, status:, track: nil, labels: [])
      @number = number
      @title = title
      @body = body
      @status = status
      @track = track
      @labels = labels
    end

    def done?
      status == "Done"
    end

    def epic?
      title.to_s.start_with?("[PRD]")
    end

    def field(key)
      key_re = /(?:\*\*)?#{LINKAGE_KEYS.fetch(key)}(?:\*\*)?/
      text = body.to_s

      line = text.lines.find { |l| l.match?(/\A[ \t]*#{key_re}[ \t]*:/) }
      if line
        return clean(line.sub(/\A[ \t]*#{key_re}[ \t]*:[ \t]*/, ""))
      end

      # The inline one-line "· Plan: value ·" form (the #104 shape).
      m = text.match(/(?:\A|[·]\s)#{key_re}[ \t]*:[ \t]*(.*?)(?:\s*·|[\n\r])/m)
      return nil unless m

      clean(m[1])
    end

    def dep_numbers(key)
      value = field(key)
      return [] if value.nil? || NONE_TOKEN.match?(value)

      value.scan(/#(\d+)/).map { |m| m[0].to_i }
    end

    def depends_on
      dep_numbers("depends")
    end

    def blocks
      dep_numbers("blocks")
    end

    # Every plan id this item cites — used by condition (a). A PRD citation
    # counts when the §7 table maps it to an item.
    def cited_ids(plan)
      ids = []
      ids.concat(title_ids)
      ids.concat(plan_line_ids)
      ids << prose_item_id if prose_item_id
      ids << plan.prd_map[prd_number] if prd_number && plan.prd_map[prd_number]
      ids.compact.uniq
    end

    # The item this ticket belongs to for the §7 index, or nil.
    def item_id(plan)
      id = title_ids.detect { |t| plan.item_ids.include?(t) }
      return id if id

      id = plan_line_item_id
      return id if id

      return plan.prd_map[prd_number] if prd_number && plan.prd_map[prd_number]
      return prose_item_id if prose_item_id
      return plan.prd_map[label_prd_number] if label_prd_number && plan.prd_map[label_prd_number]

      nil
    end

    def title_ids
      title.to_s.scan(/\[(W\d+(?:\.\d+)?)\]/).flatten
    end

    def plan_line_ids
      value = field("plan")
      return [] unless value

      ids = []
      ids << normalize_anchor(value) if value.match?(/#/)
      ids.concat(value.scan(/\bW\d+\.\d+\b/))
      ids.compact.uniq
    end

    def plan_line_item_id
      plan_line_ids.detect { |id| plan_item_id_shape?(id) }
    end

    def prose_item_id
      body.to_s.match(/Plan item \*\*(W\d+\.\d+)\*\*/)&.[](1)
    end

    def prd_number
      value = field("prd")
      if value && (m = value.match(/(0\d{3})/))
        return m[1]
      end
      return m[1] if (m = title.to_s.match(/PRD\s*(0\d{3})/))

      label_prd_number
    end

    def label_prd_number
      label = labels.detect { |l| l.start_with?("prd:") }
      label&.sub(/\Aprd:/, "")
    end

    private

    def clean(value)
      value = value.to_s.strip.gsub(/`/, "")
      return nil if value.empty?

      value = value.split("·").first.strip
      value.empty? ? nil : value
    end

    def plan_item_id_shape?(id)
      id.match?(/\AW\d+\.\d+\z/)
    end

    # `#w13-repo-conventions` → W1.3 · `#w1--core-infrastructure` → W1
    def normalize_anchor(value)
      m = value.match(/#w(\d+)/i)
      return nil unless m

      digits = m[1].to_i
      return "W#{digits}" if digits < 10

      first, rest = digits.divmod(10)
      rest == 0 ? "W#{first}" : "W#{first}.#{rest}"
    end
  end

  class Board
    attr_reader :items

    def initialize(items)
      @items = items
      @by_number = items.each_with_object({}) { |it, h| h[it.number] = it }
    end

    def [](number)
      @by_number[number]
    end

    def self.from_json(payload)
      data = JSON.parse(payload)
      new(data.fetch("items").map { |raw| item_from_raw(raw) })
    end

    # One REST call reads the whole board; a payload that fills the page limit
    # means silently missing items, which is worse than a failure.
    def self.read(root: Dir.pwd, owner: "pi-216", project_number: 5, limit: 300, runner: nil)
      runner ||= default_runner(root)
      cmd = [ "gh", "project", "item-list", project_number.to_s, "--owner", owner, "--limit", limit.to_s, "--format", "json" ]
      payload = runner.call(cmd)
      data = JSON.parse(payload)
      raw_items = data.fetch("items")
      raise ReadError, "board returned #{raw_items.size} items at the #{limit} page limit — raise the limit before trusting this read" if raw_items.size >= limit

      new(raw_items.map { |raw| item_from_raw(raw) })
    end

    def self.default_runner(root)
      lambda do |cmd|
        out, err, status = Open3.capture3(*cmd, chdir: root)
        raise ReadError, "board read failed (exit #{status.exitstatus}): #{err.strip}" unless status.success?

        out
      end
    end

    def self.item_from_raw(raw)
      content = raw.fetch("content")
      new_item = Item.new(
        number: content.fetch("number"),
        title: content.fetch("title"),
        body: content["body"],
        status: raw["status"].to_s,
        track: raw["track"],
        labels: Array(raw["labels"])
      )
      new_item
    end
  end

  Row = Struct.new(:id, :cells, :raw, keyword_init: false) do
    def state
      cells[3]
    end

    def state=(value)
      cells[3] = value
    end
  end

  Section = Struct.new(:section_id, :rows, :header, keyword_init: true)

  class PlanDoc
    attr_reader :item_ids, :workstream_ids, :prd_map, :sections

    def self.parse(text)
      new.parse!(text)
    end

    def parse!(text)
      @text = text
      @item_ids = Set.new
      @workstream_ids = Set.new
      @prd_map = {}
      @sections = {}

      text.scan(/^\|\s*\**\s*(W\d+\.\d+)\s*\**\s*\|/).map { |m| m[0] }.each { |id| @item_ids << id }
      text.scan(/^###\s+(W\d+)\s+—/).map { |m| m[0] }.each { |id| @workstream_ids << id }
      text.each_line do |line|
        if (m = line.match(/^\|\s*\**\s*(W\d+\.\d+)\s*\**\s*\|/))
          cells = line.split("|")
          if (prd = cells[3]&.match(/(0\d{3})/))
            @prd_map[prd[1]] = m[1]
          end
        end
      end

      parse_sections!
      self
    end

    def all_ids
      @item_ids.to_a + @workstream_ids.to_a
    end

    private

    def parse_sections!
      return unless @text.include?("<!-- plan:index:start")

      @text.scan(/<!-- plan:index:start (\S+) -->(.*?)<!-- plan:index:end \1 -->/m) do |section_id, body|
        rows = []
        header = nil
        body.each_line do |line|
          stripped = line.strip
          next unless stripped.start_with?("|")

          cells = line.strip.sub(/\A\|/, "").sub(/\|\z/, "").split("|").map(&:strip)
          if cells.first == "id"
            header = line
          elsif cells.first.match?(/\A-+\z/)
            # separator row — re-emitted from the first row's shape
          else
            id = cells.first.delete("*").strip
            id = nil if id == "—" || !id.match?(/\AW\d+\.\d+\z/)
            rows << Row.new(id, cells, line)
          end
        end
        @sections[section_id] = Section.new(section_id: section_id, rows: rows, header: header)
      end
    end
  end

  class Index
    ChangedRow = Struct.new(:id, :before, :after, keyword_init: true)

    def initialize(board:, plan:, plan_path:)
      @board = board
      @plan = plan
      @plan_path = plan_path
    end

    # Rewrites the state column of every marked §7 table from the board.
    # Returns the changed rows; writes the file only when something changed.
    def rewrite!
      text = File.read(@plan_path)
      raise ReadError, "no plan:index markers in #{File.basename(@plan_path)} — wrap the §7 tables first" unless text.include?("<!-- plan:index:start")

      changed = []
      # gsub's block yields only the full match; the captures come via $1..$3.
      # Grab them into locals before rebuild_section — its scan/match calls
      # overwrite the match globals. The close marker is a lookahead: it stays
      # in the file, and the rebuilt rows are newline-joined with no trailing
      # newline, so an unchanged section is byte-identical.
      new_text = text.gsub(/(<!-- plan:index:start (\S+) -->\n)(.*?)(?=\n<!-- plan:index:end \2 -->)/m) do
        open_marker, section_id, body = $1, $2, $3
        rebuilt = rebuild_section(section_id, body, changed)
        open_marker + rebuilt
      end

      if new_text != text
        File.write(@plan_path, new_text)
      end
      changed
    end

    private

    def rebuild_section(section_id, body, changed)
      body.split("\n").map do |line|
        stripped = line.strip
        unless stripped.start_with?("|")
          line
          next
        end

        cells = stripped.sub(/\A\|/, "").sub(/\|\z/, "").split("|").map(&:strip)
        id = cells.first.delete("*").strip
        id = nil unless id.match?(/\AW\d+\.\d+\z/)

        if id.nil?
          # header, separator, or a row without a plan id (the parked row) — untouched
          line
        else
          new_state = state_cell_for(id)
          if normalize(new_state) != normalize(cells[3].to_s)
            changed << ChangedRow.new(id: id, before: cells[3].to_s, after: new_state)
            cells[3] = new_state
          end
          "| #{cells.join(" | ")} |"
        end
      end.join("\n")
    end

    def state_cell_for(id)
      PlanLinkage.state_cell(@board, @plan, id)
    end

    def normalize(value)
      value.to_s.gsub(/\s+/, " ").strip
    end
  end

  class Check
    Violation = Struct.new(:kind, :message, keyword_init: true)

    def initialize(board:, plan:)
      @board = board
      @plan = plan
    end

    def violations
      no_plan_id + unknown_plan_id + stale_index + dependency_cycles + unmet_dependencies
    end

    private

    def open_items
      @board.items.reject(&:done?)
    end

    def no_plan_id
      open_items.filter_map do |item|
        next if item.cited_ids(@plan).any?

        Violation.new(kind: "no-plan-id", message: "##{item.number} (#{item.status}) cites no plan id — add the [Wx.y] title prefix or a Plan: line")
      end
    end

    def unknown_plan_id
      known = @plan.all_ids.to_set
      open_items.filter_map do |item|
        unknown = item.cited_ids(@plan).reject { |id| known.include?(id) }
        next if unknown.empty?

        Violation.new(kind: "unknown-plan-id", message: "##{item.number} cites plan id(s) #{unknown.join(", ")} not in docs/PROJECT_PLAN.md")
      end
    end

    def stale_index
      @plan.sections.filter_map do |_section_id, section|
        section.rows.filter_map do |row|
          next if row.id.nil?

          expected = state_cell_for(row.id)
          next if normalize(expected) == normalize(row.state)

          Violation.new(kind: "stale-index", message: "plan index #{row.id} is stale (board: #{expected}) — run rake plan:index")
        end
      end.flatten
    end

    def dependency_cycles
      cycle = find_cycle(edges)
      return [] if cycle.nil?

      [ Violation.new(kind: "dependency-cycle", message: "dependency cycle: #{cycle.map { |n| "##{n}" }.join(" → ")}") ]
    end

    def unmet_dependencies
      @board.items.filter_map do |item|
        next unless item.status == "In Progress"

        item.depends_on.filter_map do |dep|
          target = @board[dep]
          if target.nil?
            Violation.new(kind: "unmet-dependency", message: "##{item.number} is In Progress but depends on ##{dep}, which is not on the board")
          elsif !target.done?
            Violation.new(kind: "unmet-dependency", message: "##{item.number} is In Progress but ##{dep} is #{target.status}, not Done")
          end
        end
      end.flatten
    end

    # Depends on D → edge D → item (D must land first). Blocks B → edge
    # item → B. A consistent pair (A blocks B / B depends on A) is one edge
    # and can never cycle.
    def edges
      edges = Hash.new { |h, k| h[k] = [] }
      @board.items.each do |item|
        item.depends_on.each { |dep| edges[dep] << item.number }
        item.blocks.each { |blocked| edges[item.number] << blocked }
      end
      edges
    end

    def find_cycle(edges)
      color = Hash.new(:white)
      stack = []
      result = []

      visit = lambda do |node|
        return unless result.empty?

        color[node] = :gray
        stack.push(node)
        (edges[node] || []).each do |next_node|
          if color[next_node] == :gray
            result.replace(stack[stack.index(next_node)..] + [ next_node ])
          elsif color[next_node] == :white
            visit.call(next_node)
          end
        end
        stack.pop
        color[node] = :black
      end

      (edges.keys + edges.values.flatten).uniq.each { |node| visit.call(node) if color[node] == :white }
      result.empty? ? nil : result
    end

    def state_cell_for(id)
      PlanLinkage.state_cell(@board, @plan, id)
    end

    def normalize(value)
      value.to_s.gsub(/\s+/, " ").strip
    end
  end

  # The §7 state cell: board facts only. Plan annotations (rulings, cadence)
  # live in the prose bullets — a generated cell that carries them is two
  # truths.
  def self.state_cell(board, plan, id)
    tickets = board.items.select { |item| !item.epic? && item.item_id(plan) == id }
    epic = board.items.find { |item| item.epic? && item.item_id(plan) == id }

    parts = []
    parts << (tickets.all?(&:done?) ? "**done**" : "**open**") if tickets.any?
    parts << "epic ##{epic.number}" if epic
    parts << "tickets #{compact_numbers(tickets.map(&:number))}" if tickets.any?
    done = tickets.count(&:done?)
    parts << "#{done}/#{tickets.size} done" if tickets.any? && done < tickets.size
    return "no tickets yet" if parts.empty?

    parts.join(" · ")
  end

  def self.compact_numbers(numbers)
    sorted = numbers.uniq.sort
    runs = []
    sorted.each do |n|
      if runs.last && n == runs.last.last + 1
        runs.last << n
      else
        runs << [ n ]
      end
    end
    runs.map do |run|
      if run.size > 1
        "##{run.first}–##{run.last}"
      else
        "##{run.first}"
      end
    end.join(", ")
  end
end
