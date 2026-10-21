# frozen_string_literal: true

# PRD 0006 W1.4 · ticket #90. The parity audit runs as a subprocess: it boots
# its own app for the live mechanism probes, so it cannot share this process's
# booted environment. Mirrors spec/parity_audit_spec.rb.
#
# No DB and no mocks: the audit reads the repo on disk. The one mutation
# (the layout head meta) is restored by the After hook, so a failing step
# can never leave the tree dirty for the next scenario.
require "open3"

RAIL_LINE = /\AR([1-9])  (CONFORM|GAP|DEVIATION)  .+\z/

def run_parity_audit!
  out, _err, status = Open3.capture3("bundle exec ruby scripts/parity_audit.rb", chdir: Rails.root)
  @parity_lines = out.lines.map(&:chomp)
  @parity_exit = status.exitstatus
end

Given("the parity audit script is run against the repo") do
  run_parity_audit!
end

When("it completes") do
  expect(@parity_lines).not_to be_nil
  expect(@parity_exit).not_to be_nil
end

Then(/it prints one line per template rail: CONFORM, GAP, or DEVIATION\(reason\)/) do
  9.times do |i|
    expect(@parity_lines[i]).to match(RAIL_LINE), "rail line #{i + 1} is malformed: #{@parity_lines[i].inspect}"
    expect(@parity_lines[i][0..1]).to eq("R#{i + 1}"), "rail lines must run R1..R9 in order: #{@parity_lines[i].inspect}"
  end
  expect(@parity_lines[9]).to match(/\APARITY (OK|FAILED)/)
end

Then("no template rail is in GAP") do
  expect(@parity_lines[0...9]).not_to include(a_string_matching(/\AR[1-9]  GAP/))
  expect(@parity_lines[9]).to match(/\APARITY OK — \d+ CONFORM, \d+ DEVIATION, 0 GAP/)
end

When("the turbo refresh meta is deleted from the layout head, the audit is re-run") do
  layout = Rails.root.join("app/views/layouts/application.html.erb")
  @layout_original = layout.read
  layout.write(@layout_original.sub(%r{<meta name="turbo-refresh-method" content="morph">\n?}, ""))
  run_parity_audit!
end

Then("the audit reports the Turbo rail in GAP") do
  expect(@parity_lines[1]).to match(/\AR2  GAP  /)
end

And("the audit exits non-zero") do
  expect(@parity_exit).not_to eq(0)
end

After do
  if @layout_original
    Rails.root.join("app/views/layouts/application.html.erb").write(@layout_original)
    @layout_original = nil
  end
end
