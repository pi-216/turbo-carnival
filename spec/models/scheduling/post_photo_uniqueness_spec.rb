# frozen_string_literal: true

require 'rails_helper'

# ONE POST PER PHOTO PER PERSONA -- the guarantee Growth::LibraryFallback#spend,
# Growth::RenderSalvage and the growth producers all rely on as their
# idempotency MARKER ("a Post row for this photo is the marker").
#
# WHY IT IS TESTED AT THE DATABASE LEVEL: the callers are CONCURRENT.
# bin/scheduled_posting.sh (hourly, APPLY=1) and Growth::AbandonedRenderWorker
# (every 5 min, GPU-free) are both armed, are triggered by the same condition
# (publish runway inside RUNWAY_TRIGGER_H) and both select the same candidates
# newest-first, spending ~16-20s in the two gates before INSERTing -- so an
# interleaved pair both passes the check-then-act `exists?` and both creates a
# post for the same photo. A model validation alone cannot hold that race.
#
# Measured 2026-09-23 (ops-triage): the code comment asserted this uniqueness as
# fact while the schema carried only a plain photo_id index and the model no
# such validation -- so the marker's guarantee was prose, not enforcement.
RSpec.describe Scheduling::Post do
  let(:persona) { create(:persona) }
  let(:other_persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }

  let(:photo) do
    path = Rails.root.join('tmp', "post_uniqueness_spec_#{SecureRandom.hex(6)}.png").to_s
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, 'not-really-a-png')
    @paths << path
    ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: path,
                                  synthetic: true, provenance: { 'source' => 'spec' })
  end

  before { @paths = [] }
  after { @paths.each { |p| FileUtils.rm_f(p) } }

  def post_for(persona:, photo:, caption: 'x')
    Scheduling::Post.create!(persona: persona, photo: photo, caption: caption,
                             status: 'scheduled', scheduled_at: 1.day.from_now,
                             optimal_time_calculated: 1.day.from_now,
                             strategy_name: 'spec')
  end

  it 'rejects a second post for the same photo and persona' do
    post_for(persona: persona, photo: photo)

    dup = Scheduling::Post.new(persona: persona, photo: photo, caption: 'again',
                               status: 'scheduled', scheduled_at: 2.days.from_now,
                               optimal_time_calculated: 2.days.from_now)

    expect(dup).not_to be_valid
    expect(dup.errors[:photo_id]).to be_present
    expect { dup.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'enforces it in the database, not only in the model' do
    post_for(persona: persona, photo: photo)

    # Savepoint, so the aborted inner statement cannot poison the example's
    # surrounding transaction.
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(<<~SQL)
          INSERT INTO scheduling_posts (photo_id, persona_id, status, caption, created_at, updated_at)
          VALUES (#{photo.id}, #{persona.id}, 'scheduled', 'raw second', now(), now())
        SQL
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'scopes the guarantee to the persona -- another persona may post the same photo' do
    post_for(persona: persona, photo: photo)

    expect { post_for(persona: other_persona, photo: photo) }.not_to raise_error
  end

  it 'leaves drafts without a photo unrestricted' do
    # awaiting_image drafts carry photo_id NULL, and Postgres treats NULLs as
    # distinct in a unique index -- several may coexist.
    expect do
      2.times { |i| Scheduling::Post.create!(persona: persona, caption: "draft #{i}", status: 'draft') }
    end.not_to raise_error
  end
end
