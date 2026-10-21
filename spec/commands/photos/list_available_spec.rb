# frozen_string_literal: true

require 'rails_helper'

# PRD 0007 B3: the realism measurement is advisory, so its thresholds are SELECTION
# defaults -- they ORDER the pool and never filter it. This selector is where the
# "low-priority, not purged" half of the ruling is actually enforced, so these
# examples are the contract for it: a below-default asset is ranked last, stays
# listed, and an UNMEASURED one is not treated as a bad one.
RSpec.describe Photos::ListAvailable do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  before { @paths = [] }
  after { @paths.each { |p| FileUtils.rm_f(p) } }

  def photo!(aesthetic_score: nil, sharpness: nil, created_at: nil)
    path = Rails.root.join('tmp', "list_available_spec_#{SecureRandom.hex(6)}.png").to_s
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, 'not-really-a-png')
    @paths << path
    ContentPillars::Photo.create!(
      persona: persona, content_pillar: pillar, path: path, synthetic: true,
      aesthetic_score: aesthetic_score, sharpness: sharpness,
      created_at: created_at || Time.current
    )
  end

  def listed(**opts)
    described_class.call(persona: persona, **opts).photos
  end

  it 'ranks a below-default asset last instead of dropping it' do
    soft = photo!(aesthetic_score: 3.1, sharpness: 9.4, created_at: 1.minute.ago) # newest
    sharp = photo!(aesthetic_score: 6.2, sharpness: 120.0, created_at: 5.minutes.ago)

    expect(listed.map(&:id)).to eq([ sharp.id, soft.id ])
  end

  it 'keeps a below-default asset in the pool — nothing is purged or hidden' do
    soft = photo!(aesthetic_score: 3.1, sharpness: 9.4)

    expect(listed.map(&:id)).to include(soft.id)
  end

  it 'ranks an UNMEASURED asset by recency, not as low quality' do
    unmeasured = photo!(created_at: 1.minute.ago) # newest, never scored
    sharp = photo!(aesthetic_score: 6.2, sharpness: 120.0, created_at: 5.minutes.ago)

    expect(listed.map(&:id)).to eq([ unmeasured.id, sharp.id ])
  end

  it 'orders by recency inside the low-priority group' do
    soft_old = photo!(aesthetic_score: 3.0, sharpness: 100.0, created_at: 10.minutes.ago)
    soft_new = photo!(aesthetic_score: 3.0, sharpness: 100.0, created_at: 1.minute.ago)
    sharp = photo!(aesthetic_score: 6.0, sharpness: 100.0, created_at: 20.minutes.ago)

    expect(listed.map(&:id)).to eq([ sharp.id, soft_new.id, soft_old.id ])
  end

  it 'treats a soft render as low priority on sharpness alone' do
    soft = photo!(aesthetic_score: 6.4, sharpness: 8.0, created_at: 1.minute.ago)
    sharp = photo!(aesthetic_score: 6.2, sharpness: 120.0, created_at: 5.minutes.ago)

    expect(listed.map(&:id)).to eq([ sharp.id, soft.id ])
  end

  it 'restores pure recency for a caller that overrides the default' do
    soft = photo!(aesthetic_score: 3.1, sharpness: 9.4, created_at: 1.minute.ago)
    sharp = photo!(aesthetic_score: 6.2, sharpness: 120.0, created_at: 5.minutes.ago)

    expect(listed(low_quality_last: false).map(&:id)).to eq([ soft.id, sharp.id ])
  end

  # The selector must read the SAME defaults the gate does, so one ENV knob moves the
  # gate's `flagged` verdict and this ordering together instead of letting them drift.
  it 'honours the env override of the selection defaults' do
    # Below the aesthetic default but comfortably above the sharpness one, so the
    # override has exactly one thing to move.
    soft = photo!(aesthetic_score: 3.1, sharpness: 120.0, created_at: 1.minute.ago)
    sharp = photo!(aesthetic_score: 6.2, sharpness: 120.0, created_at: 5.minutes.ago)

    begin
      ENV['AESTHETIC_THRESHOLD'] = '3.0'

      expect(listed.map(&:id)).to eq([ soft.id, sharp.id ])
    ensure
      ENV.delete('AESTHETIC_THRESHOLD')
    end
  end

  # A post may legitimately carry NO photo -- the REELS arm publishes the composed video
  # at `reel_path` and has no single photo that "is" it. `id NOT IN (..., NULL)` is
  # UNKNOWN for EVERY row in SQL, so ONE photo-less post used to empty this selector
  # completely: measured 2026-10-21 on the live DB, a single reel post (created
  # 2026-10-12) made it return 0 candidates while 43 servable unposted photos existed,
  # which silently disabled Growth::LibraryFallback (the GPU-free reserve), the admin
  # grid and bin/library_depth.py. The sibling selector ContentStrategy::Context already
  # carried the guard.
  it 'is not emptied by a post that carries no photo' do
    photo = photo!(aesthetic_score: 6.2, sharpness: 120.0)
    Scheduling::Post.create!(persona: persona, photo: nil, caption: 'reel arm',
                             status: 'posted', strategy_name: 'reel-discovery-arm',
                             reel_path: '/tmp/does-not-need-to-exist.mp4')

    expect(listed.map(&:id)).to eq([ photo.id ])
  end

  it 'still excludes a photo a post already references' do
    photo = photo!(aesthetic_score: 6.2, sharpness: 120.0)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'used',
                             status: 'scheduled', strategy_name: 'spec')

    expect(listed).to be_empty
  end
end
