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
