require "rails_helper"

# Guard for PRD 0006 F3 / ticket #78 (and R8 / ticket #91 for the single
# lint entry point).
#
# The three gate members were absent from Gemfile.lock for as long as this repo has existed and
# nothing noticed, because nothing asserted them -- the parity audit found them by hand. This spec
# is the assertion: drop a gem, the config, or a CI step, and the suite goes red instead of the gap
# going unnoticed.
RSpec.describe "gate members (PRD 0006 F3 / ticket #78)" do
  let(:gemfile) { Rails.root.join("Gemfile").read }
  let(:ci) { Rails.root.join(".github/workflows/ci.yml").read }

  it "declares bundler-audit, erb_lint and strong_migrations in the Gemfile" do
    expect(gemfile).to match(/^\s*gem "bundler-audit"/)
    expect(gemfile).to match(/^\s*gem "erb_lint"/)
    expect(gemfile).to match(/^\s*gem "strong_migrations"/)
  end

  it "ships the .erb_lint.yml config the template pins" do
    config = Rails.root.join(".erb_lint.yml")

    expect(config).to exist
    # An empty file satisfies `exist` while linting nothing useful -- assert the substance.
    expect(config.read).to include("exclude:")
  end

  # A `require: false` here is the exact failure this ticket exists to prevent: the gem installs,
  # `bundle list` shows it, and the migrate-time checks never run.
  it "auto-requires strong_migrations so the migrate-time checks actually fire" do
    declaration = gemfile.lines.find { |line| line.include?('gem "strong_migrations"') }

    expect(declaration).not_to be_nil
    expect(declaration).not_to include("require: false")
  end

  it "runs bundler-audit as a CI gate" do
    expect(ci).to include("bundler-audit check")
  end

  # PRD 0006 R8 / ticket #91: the style linters run through the single entry
  # point; CI and bin/verify must not reach for the underlying linters
  # directly, or the rule set becomes a property of whoever ran it.
  it "runs rubocop and erb_lint through bin/lint, never directly" do
    expect(ci).to include("bin/lint")
    expect(ci).not_to include("bin/rubocop")
    expect(Rails.root.join("bin/verify").read).to include("bin/lint")
    expect(Rails.root.join("bin/verify").read).not_to include("bin/rubocop")
  end
end

# PRD 0006 R8 / ticket #91: AGENTS.md is the agent contract, so the content
# contract must stay in it — a rule with no enforcement is a preference.
RSpec.describe "AGENTS.md content contract (PRD 0006 R8 / ticket #91)" do
  let(:agents) { Rails.root.join("AGENTS.md").read }

  it "states the single lint entry point" do
    expect(agents).to include("bin/lint")
    expect(agents).to match(/single lint entry point/i)
  end

  it "states the generated-files rule (regenerated, never hand-edited)" do
    expect(agents).to match(/generated files/i)
    expect(agents).to match(/never hand-edit/i)
  end

  it "states the code-comment policy" do
    expect(agents).to match(/code comments/i)
  end

  it "states the no-exfiltration policy" do
    expect(agents).to include("exfiltration")
  end
end
