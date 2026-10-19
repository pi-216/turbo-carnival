# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the pacing on the REAL task (not just the plan object):
# two slots due in the same tick must leave the building one per run. This is the
# wiring that matters -- the publisher is the one path that must never stall, so
# the assertion is also that the DEFERRED row is untouched (still 'scheduled',
# not failed, still selected by the next run).
RSpec.describe 'scheduling:post_scheduled release pacing' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def due_post(at)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'scheduled', scheduled_at: at, optimal_time_calculated: at)
  end

  def ok(struct_name, returns)
    Struct.new(*returns.keys) { def success? = true; def errors = [] }
          .new(*returns.values)
  end

  it 'publishes only the earliest due post and leaves the rest selected' do
    earlier = due_post(2.hours.ago)
    later = due_post(1.hour.ago)

    allow(Scheduling::Commands::GeneratePublicPhotoUrl)
      .to receive(:call!).and_return(ok(:r, { public_photo_url: 'https://example.test/p.png' }))
    allow(Scheduling::Commands::SendPostToInstagram)
      .to receive(:call!).and_return(ok(:r, { instagram_post_id: 'ig-1' }))

    Rake::Task['scheduling:post_scheduled'].reenable
    Rake::Task['scheduling:post_scheduled'].invoke

    expect(earlier.reload.status).to eq('posted')
    expect(later.reload.status).to eq('scheduled')
    expect(later.reload.posted_at).to be_nil
  end
end
