# frozen_string_literal: true

# PRD 0007 A2 · ticket #105. The wardrobe is a per-pillar axis the planner sets,
# replacing the removed `PillarPrompt::SAFE_BASE` modest-clothing floor. These
# steps build a real prompt from a real pillar and assert the coverage the axis
# produced — so the render request carries the wardrobe, from the covered floor
# up to the reveal rungs, and no SFW-only default survives in the prompt path.

Given('a content pillar at wardrobe level {int}') do |level|
  @pillar = create(:content_pillar, wardrobe_level: level)
end

Given('a content pillar') do
  @pillar = create(:content_pillar)
end

Given('the wardrobe tier is at the top rung') do
  ENV[ContentPillars::WardrobeAxis::VALIDATED_TIER_ENV] =
    ContentPillars::WardrobeAxis::MAX_LEVEL.to_s
end

When('a render prompt is built') do
  @prompt = Growth::PillarPrompt.for_pillar(@pillar)
end

Then('the prompt reads a short miniskirt') do
  expect(@prompt).to match(/short miniskirt/i)
end

Then('the prompt reads fully covered clothing') do
  expect(@prompt).to match(/wearing everyday clothing, torso and legs fully covered/i)
end

Then('no SFW-only clothing default remains') do
  expect(Growth::PillarPrompt.const_defined?(:SAFE_BASE, false)).to be(false)
  expect(Growth::PillarPrompt::BASE).not_to match(/modest everyday clothing|fully dressed/i)
end

After('@DEV-0105') do
  ENV.delete(ContentPillars::WardrobeAxis::VALIDATED_TIER_ENV)
  # Roll back the records these scenarios created so the shared test DB is not
  # polluted (cucumber-rails does not clean up by default; a leaked persona would
  # collide with the rspec sequence(:name) on the next suite run).
  ActiveRecord::Base.connection.rollback_transaction if ActiveRecord::Base.connection.transaction_open?
end

Before('@DEV-0105') do
  ActiveRecord::Base.connection.begin_transaction(joinable: false)
end

# PRD 0007 B2 · ticket #109. The scene's own negative: a scene that covers the
# areola in text carries the terms in its own negative; a scene that exposes it
# in text is free of the suppression. These steps resolve the negative the way
# the production rail does — from the rung the prompt reads.
When('the scene negative is resolved for the pillar') do
  @scene_negative = ContentPillars::WardrobeAxis.negative_for(
    ContentPillars::WardrobeAxis.effective_level(@pillar)
  )
end

When('the scene negative is resolved for rung {int}') do |level|
  @scene_negative = ContentPillars::WardrobeAxis.negative_for(level)
end

Then('the scene negative reads "nipples, areola"') do
  expect(@scene_negative).to eq('nipples, areola')
end

Then('the scene negative carries no areola terms') do
  expect(@scene_negative).not_to match(/nipple|areola/i)
end

Given('a wardrobe rung that exposes the areola in text') do
  @saved_ladder = ContentPillars::WardrobeAxis.const_get(:LADDER)
  exposed = ContentPillars::WardrobeAxis.const_get(:Rung).new(
    level: ContentPillars::WardrobeAxis::MAX_LEVEL + 1,
    descriptor: 'naked, the areola visible',
    covers_areola: false
  )
  # remove_const + const_set is a fresh definition: no "already initialized
  # constant" warning in the suite output.
  ContentPillars::WardrobeAxis.send(:remove_const, :LADDER)
  ContentPillars::WardrobeAxis.const_set(:LADDER, @saved_ladder + [ exposed ])
end

Before('@DEV-0109') do
  ActiveRecord::Base.connection.begin_transaction(joinable: false)
end

After('@DEV-0109') do
  # Restore the declared scale if a scenario added a rung (a const swap in a
  # hook is visible to the whole process; the restore is the cleanup).
  if @saved_ladder
    ContentPillars::WardrobeAxis.send(:remove_const, :LADDER) if ContentPillars::WardrobeAxis.const_defined?(:LADDER)
    ContentPillars::WardrobeAxis.const_set(:LADDER, @saved_ladder)
    @saved_ladder = nil
  end
  # Same shared-DB hygiene as @DEV-0105.
  ActiveRecord::Base.connection.rollback_transaction if ActiveRecord::Base.connection.transaction_open?
end
