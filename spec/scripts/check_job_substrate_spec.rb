require "rails_helper"
require "tmpdir"
require "open3"

# PRD 0006 Q5 / ticket #85 — the job_substrate gate must FAIL when a solid_*
# reference or a non-Sidekiq ActiveJob adapter reappears. The check script is
# given a way to fail: it runs against fixture trees (a Gemfile, a Gemfile.lock,
# and a config/ dir) and asserts the exit code, so the gate is provable rather
# than a convention.
RSpec.describe "bin/check_job_substrate.rb" do
  let(:script) { Rails.root.join("bin/check_job_substrate.rb") }

  def run_check(tree)
    Open3.capture3(Rails.root.join("bin/check_job_substrate.rb").to_s, tree.to_s)
  end

  def write_fixture(root)
    File.write(File.join(root, "Gemfile"), "source :rubygems\n")
    File.write(File.join(root, "Gemfile.lock"), "GEMFILE LOCK\n")
    Dir.mkdir(File.join(root, "config"))
    File.write(
      File.join(root, "config", "application.rb"),
      "config.active_job.queue_adapter = :sidekiq\n"
    )
    root
  end

  it "passes on the live repo (Sidekiq is the sole substrate)" do
    _, _, status = run_check(Rails.root)
    expect(status.exitstatus).to eq(0)
  end

  it "passes on a clean fixture tree" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      _, _, status = run_check(dir)
      expect(status.exitstatus).to eq(0)
    end
  end

  it "fails when a solid_* reference reappears in the Gemfile" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      File.write(File.join(dir, "Gemfile"), "source :rubygems\ngem \"solid_queue\"\n")
      out, _, status = run_check(dir)
      expect(status.exitstatus).to eq(1)
      expect(out).to include("solid_* reference")
    end
  end

  it "fails when an environment configures a non-Sidekiq adapter" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      File.write(
        File.join(dir, "config", "production.rb"),
        "config.active_job.queue_adapter = :solid_queue\n"
      )
      out, _, status = run_check(dir)
      expect(status.exitstatus).to eq(1)
      expect(out).to include("not :sidekiq")
    end
  end

  it "fails when no ActiveJob adapter is configured at all" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      File.write(File.join(dir, "config", "application.rb"), "")
      out, _, status = run_check(dir)
      expect(status.exitstatus).to eq(1)
      expect(out).to include("no active_job.queue_adapter configured")
    end
  end

  it "fails closed on a target that is not a repo tree" do
    Dir.mktmpdir do |dir|
      out, _, status = run_check(dir) # no Gemfile
      expect(status.exitstatus).to eq(1)
      expect(out).to include("no Gemfile")
    end
  end
end
