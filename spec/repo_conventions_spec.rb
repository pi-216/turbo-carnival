require "rails_helper"

# Guard for PRD 0006 F3 / ticket #78.
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

  it "runs bundler-audit and erb_lint as CI gates" do
    expect(ci).to include("bundler-audit check")
    expect(ci).to include("erb_lint --lint-all")
  end
end
