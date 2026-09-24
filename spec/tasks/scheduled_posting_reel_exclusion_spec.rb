# frozen_string_literal: true

require 'rails_helper'

# The REELS rail's rows are legal on `scheduling_posts` and may be due while the
# still rail runs (ops 2026-09-24: `reel_path` + no photo is a valid scheduled
# post). The still publisher resolves `post.photo` at publish time
# (GeneratePublicPhotoUrl), so a due reel post reaching it would raise inside the
# release loop and could take other due stills down with it.
#
# The rule under test: the still rail publishes STILLS, ignores reel posts, and
# does not touch their state or steal their slot.
RSpec.describe 'scheduling:post_scheduled reel exclusion' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def still_due_post(at)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'scheduled', scheduled_at: at, optimal_time_calculated: at)
  end

  def ok(struct_name, returns)
    Struct.new(*returns.keys) { def success? = true; def errors = [] }
          .new(*returns.values)
  end

  it 'leaves a due reel post untouched instead of raising on its nil photo' do
    still = still_due_post(2.hours.ago)
    reel = Scheduling::Post.create!(persona: persona, status: 'scheduled',
                                    scheduled_at: 1.hour.ago, optimal_time_calculated: 1.hour.ago,
                                    reel_path: '/nonexistent/reel.mp4', caption: 'a reel caption')

    allow(Scheduling::Commands::GeneratePublicPhotoUrl)
      .to receive(:call!).and_return(ok(:r, { public_photo_url: 'https://example.test/p.png' }))
    allow(Scheduling::Commands::SendPostToInstagram)
      .to receive(:call!).and_return(ok(:r, { instagram_post_id: 'ig-1' }))

    Rake::Task['scheduling:post_scheduled'].reenable
    expect { Rake::Task['scheduling:post_scheduled'].invoke }.not_to raise_error

    expect(still.reload.status).to eq('posted')
    expect(reel.reload.status).to eq('scheduled')
    expect(reel.reload.posted_at).to be_nil
    expect(reel.reload.provider_post_id).to be_nil
  end
end
