require "rails_helper"
require "open3"

# Guard for PRD 0006 W1.4 / ticket #90.
#
# The parity audit (scripts/parity_audit.rb) is the enforcement line for the
# nine template rails; this spec is the enforcement line for the enforcement
# line. It runs the script as a subprocess (the script boots its own app) and
# asserts the output contract, then proves each sabotage path the PRD requires:
#
#   * one line per rail R1–R9, each CONFORM / GAP / DEVIATION(reason);
#   * non-zero exit while any rail is GAP; zero when only approved deviations
#     remain;
#   * delete the head meta (or drop a pack dir) → that rail is GAP → non-zero;
#     restore → zero;
#   * a rail with no disposition fails the script (exit 2) — no silent
#     "missing".
#
# The expected verdicts below encode the ratified dispositions as of the pins
# the script records (PRD 0006 rulings Q1/Q5/Q7/Q8, tickets #84/#85/#91, and
# the dormant API lane). When one of those closes, the rail line changes and
# this expectation must change with it — a rail-state change is a reviewable
# event, not a silent one.
RSpec.describe "parity audit (PRD 0006 W1.4 / ticket #90)" do
  RAIL_LINE = /\AR([1-9])  (CONFORM|GAP|DEVIATION)  .+\z/

  def run_audit(extra_env: {})
    out, err, status = Open3.capture3(extra_env, "bundle exec ruby scripts/parity_audit.rb", chdir: Rails.root)
    { out: out, err: err, exit: status.exitstatus }
  end

  def rail_lines(result)
    result[:out].lines.map(&:chomp)
  end

  it "prints exactly one line per template rail, in order, with a valid verdict, and exits zero" do
    result = run_audit

    expect(result[:exit]).to eq(0)
    lines = rail_lines(result)
    expect(lines.size).to eq(10), "expected 9 rail lines + 1 summary line, got:\n#{lines.join("\n")}"

    9.times do |i|
      expect(lines[i]).to match(RAIL_LINE), "rail line #{i + 1} is malformed: #{lines[i].inspect}"
      expect(lines[i][0..1]).to eq("R#{i + 1}"), "rail lines must run R1..R9 in order: #{lines[i].inspect}"
    end
    expect(lines[9]).to match(/\APARITY OK — \d+ CONFORM, \d+ DEVIATION, 0 GAP/)
  end

  it "reads the ratified state: six rails conform, three carry approved deviations" do
    lines = rail_lines(run_audit)
    verdict = ->(i) { lines[i].split("  ", 3)[1] }

    expect(verdict.call(1)).to eq("CONFORM") # R2 Turbo liveness
    expect(verdict.call(2)).to eq("CONFORM") # R3 command rail
    expect(verdict.call(4)).to eq("CONFORM") # R5 BDD pipeline
    expect(verdict.call(5)).to eq("CONFORM") # R6 quality gates
    expect(verdict.call(6)).to eq("CONFORM") # R7 observability
    expect(verdict.call(0)).to eq("DEVIATION") # R1 — Q1 HAML, Q7 state machine, Q5 solid_*
    expect(verdict.call(3)).to eq("DEVIATION") # R4 — Q8 packs-rails wiring
    expect(verdict.call(7)).to eq("CONFORM") # R8 — #91 landed (bin/lint single entry point)
    expect(verdict.call(8)).to eq("DEVIATION") # R9 — API lane dormant
  end

  it "turns R2 GAP and exits non-zero while the head meta is deleted, then returns to zero" do
    layout = Rails.root.join("app/views/layouts/application.html.erb")
    original = layout.read

    layout.write(original.sub(/<meta name="turbo-refresh-method" content="morph">\n?/, ""))
    result = run_audit

    expect(result[:exit]).not_to eq(0)
    expect(rail_lines(result)[1]).to match(/\AR2  GAP  /)
    expect(rail_lines(result)[9]).to match(/\APARITY FAILED — GAP on R2/)
  ensure
    layout.write(original)
  end

  it "turns R4 GAP and exits non-zero while the probe constant's file is dropped, then returns to zero" do
    model_file = Rails.root.join("packs/growth_harness/app/models/growth/goal.rb")
    backup = model_file.sub_ext(".rb.hidden")
    FileUtils.mv(model_file, backup)
    result = run_audit

    expect(result[:exit]).not_to eq(0)
    expect(rail_lines(result)[3]).to match(/\AR4  GAP  /)
    expect(rail_lines(result)[9]).to match(/\APARITY FAILED — GAP on R4/)
  ensure
    FileUtils.mv(backup, model_file) if File.exist?(backup) && !File.exist?(model_file)
  end

  it "turns R6 GAP and exits non-zero while a ported artifact drifts from its pin" do
    artifact = Rails.root.join("bin/rspec")
    original = artifact.read
    artifact.write(original + "# drift\n")
    result = run_audit

    expect(result[:exit]).not_to eq(0)
    expect(rail_lines(result)[5]).to match(/\AR6  GAP +byte-identity drift: bin\/rspec/)
  ensure
    artifact.write(original)
  end

  it "fails the script (exit 2) when a rail has no disposition — never a silent missing" do
    result = run_audit(extra_env: { "PARITY_AUDIT_SKIP" => "R9" })

    expect(result[:exit]).to eq(2)
    expect(rail_lines(result)).to include(a_string_starting_with("PARITY ERROR — no disposition for R9"))
  end

  it "is wired into bin/verify as a gate member before the rspec lane" do
    verify = Rails.root.join("bin/verify").read
    parity_idx = verify.index(/run_gate "parity"/)
    rspec_idx = verify.index(/AGENT_TEST=1\s+bin\/rspec/)

    expect(parity_idx).not_to be_nil
    expect(rspec_idx).not_to be_nil
    expect(parity_idx).to be < rspec_idx
  end
end
