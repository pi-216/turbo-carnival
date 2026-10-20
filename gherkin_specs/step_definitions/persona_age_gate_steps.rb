# frozen_string_literal: true

# PRD 0007 B1 · ticket #108. The pre-publish age gate is tier-aware: a band
# whose top reaches 18 publishes at the SFW tier (the ~18yo pull is the read
# target, not a violation) and is recorded on the row; the explicit tier
# publishes only on a verified adult band, and a minor read holds at every
# tier. These steps queue a real post, feed the gate a fixed vision read, and
# assert the write path.
#
# The probe is the only seam. cucumber has no per-example mock lifecycle (see
# world_helpers.rb), so the Given step swaps `CaptionGeneration::VisionProbe`
# for a class that answers with the scenario's read, and After restores the
# real one. Records are rolled back the same way as the other harness
# scenarios so the shared test DB is not polluted.

Given('a queued {word}-tier post whose age read is {string}') do |tier, read|
  persona = create(:persona)
  pillar = create(:content_pillar, persona: persona)
  create(:growth_goal, persona: persona)
  photo = ContentPillars::Photo.create!(persona: persona, path: "gherkin-#{SecureRandom.hex(4)}.png",
                                        content_pillar: pillar)
  slot = 2.days.from_now
  @post = Scheduling::Post.create!(persona: persona, photo: photo, caption: 'gherkin', status: 'scheduled',
                                   scheduled_at: slot, optimal_time_calculated: slot)

  tier_line = tier.to_s.casecmp?('explicit') ? 'EXPLICIT' : 'SFW'
  result = @vision_probe_class::Result.new(text: "AGE: #{read}\nTIER: #{tier_line}\nCUES: gherkin scenario",
                                           model: 'gherkin')
  stub = Class.new do
    define_method(:ok?) { result.ok? }
    define_method(:text) { result.text }
    define_method(:model) { result.model }
    define_method(:model_selection) { 'gherkin' }
    define_method(:error) { result.error }
  end
  stub.define_singleton_method(:ask) { |**| stub.new }
  CaptionGeneration.send(:const_set, :VisionProbe, stub)
end

When('the persona age gate runs with writes enabled') do
  @gate_results = Growth::PersonaAgeGate.call(persona: @post.persona, dry_run: false)
end

Then('the post keeps its slot') do
  post = @post.reload
  expect(post.scheduled_at).to be_a(Time)
  expect(post.optimal_time_calculated).to be_a(Time)
end

Then('the read is recorded on the row with band {string} and tier {string}') do |band, tier|
  gate = @post.reload.caption_metadata['age_gate']
  expect(gate).to be_a(Hash)
  expect(gate['held']).to be(false)
  expect(gate['tier']).to eq(tier)
  expect(gate['band'].map { |n| Float(n) }).to eq(band.split('-').map { |n| Float(n) })
end

Then('the post is held with both publisher clocks cleared') do
  post = @post.reload
  expect(post.scheduled_at).to be_nil
  expect(post.optimal_time_calculated).to be_nil
  expect(post.status).to eq('scheduled')
  expect(post.caption_metadata['age_gate']['held']).to be(true)
end

Then('a growth decision records the hold') do
  decision = Growth::Decision.find_by(action: 'age_gate_hold')
  expect(decision).not_to be_nil
  expect(decision.reason).to include("post #{@post.id}")
end

Before('@DEV-0108') do
  @vision_probe_class = CaptionGeneration::VisionProbe
  ActiveRecord::Base.connection.begin_transaction(joinable: false)
end

After('@DEV-0108') do
  CaptionGeneration.send(:const_set, :VisionProbe, @vision_probe_class)
  ActiveRecord::Base.connection.rollback_transaction if ActiveRecord::Base.connection.transaction_open?
end
