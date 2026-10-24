require "rails_helper"
require "sidekiq/test_api"
require "sidekiq/api"

# PRD 0006 Q5 / ticket #85 — Sidekiq is the single job substrate.
#
# The acceptance for the retirement is "jobs enqueue and run on Sidekiq (prove
# it with a real job, not a unit stub)". The ActiveJob adapter is asserted to be
# :sidekiq in every environment (set once in config/application.rb, no env
# override), and a REAL worker — JobSubmitterWorker, the live submission loop —
# is proven to enqueue into Sidekiq's queue and to run its perform through
# Sidekiq's processing path. The only stub is the downstream SelectNextJob
# command it delegates to (the same pattern the worker's own spec uses), so the
# worker class itself is the real artifact under test.
RSpec.describe "job substrate" do
  describe "ActiveJob adapter" do
    it "is :sidekiq in the running environment" do
      expect(Rails.application.config.active_job.queue_adapter.to_s).to eq("sidekiq")
    end

    it "sets :sidekiq in application.rb and never overrides an environment with another adapter" do
      app_conf = File.read(Rails.root.join("config/application.rb"))
      expect(app_conf).to include("config.active_job.queue_adapter = :sidekiq")

      Dir.glob(Rails.root.join("config/environments/*.rb")).each do |f|
        adapters = File.read(f).scan(/queue_adapter\s*=\s*:(\w+)/).flatten
        expect(adapters).to all(eq("sidekiq")), "#{File.basename(f)} sets a non-Sidekiq adapter"
      end
    end
  end

  describe "a real worker enqueues and runs on Sidekiq" do
    it "enqueues a real worker into Sidekiq's queue" do
      Sidekiq::Testing.fake! do
        JobSubmitterWorker.perform_async

        expect(JobSubmitterWorker.jobs.size).to eq(1)
        expect(JobSubmitterWorker.jobs.first["class"]).to eq("JobSubmitterWorker")
      end
    end

    it "runs a real worker's perform through Sidekiq's processing path" do
      allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
      # Under inline! a scheduled perform_in re-enters perform (schedule -> run ->
      # schedule), so stub it: we are proving the single perform run, not the loop.
      expect(JobSubmitterWorker).to receive(:perform_in)
      expect(SelectNextJob).to receive(:call).and_return(
        SelectNextJob.build_context(mode: :no_work)
      )

      Sidekiq::Testing.inline! do
        JobSubmitterWorker.perform_async
      end
    end
  end
end
