# frozen_string_literal: true

require 'rails_helper'

# The persona's stored prompt carried NO age token, so the model chose one and
# the account's renders read as teenagers. These examples pin the anchor's scope:
# it is added to the persona's positive prompt only, it never removes an identity
# token, it is idempotent, and it survives the render-time prompt guard (a write
# the guard would rewrite is theatre).
RSpec.describe PersonaAgeAnchor do
  let(:prompt) do
    "score_9, score_8_up, score_7_up\n\nAdd more details\npetite face, small nose, s1_dram, sarah1a3\n\n" \
      "warm, friendly, natural, wholesome\n\nsarah1a3, slender, freckles, casual everyday outfit\n"
  end
  let(:workflow) do
    { '88' => { 'class_type' => 'Text Multiline', 'inputs' => { 'text' => prompt } } }
  end

  it 'prepends the anchor to the identity line, keeping every original token' do
    anchored, changes = described_class.anchor_workflow(workflow)

    expect(changes.size).to eq(1)
    text = anchored['88']['inputs']['text']
    expect(text).to include("#{described_class::ANCHOR}, petite face, small nose, s1_dram, sarah1a3")
    expect(text).to include('slender, freckles, casual everyday outfit')
    expect(text.scan('sarah1a3').size).to eq(2) # nothing removed
  end

  it 'is idempotent: an anchored prompt is left alone' do
    anchored, = described_class.anchor_workflow(workflow)
    again, changes = described_class.anchor_workflow(anchored)

    expect(changes).to be_empty
    expect(again['88']['inputs']['text']).to eq(anchored['88']['inputs']['text'])
  end

  it 'ignores text that does not name the persona identity' do
    other = { '79' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => 'worst quality, low quality' } } }

    _anchored, changes = described_class.anchor_workflow(other)

    expect(changes).to be_empty
  end

  it 'survives the render-time prompt guard, so the anchor is not stripped' do
    anchored, = described_class.anchor_workflow(workflow)

    _guarded, guard_changes = PipelinePromptSafety.sanitize_workflow(anchored)

    expect(guard_changes).to be_empty
    expect(anchored['88']['inputs']['text']).to include(described_class::ANCHOR)
  end
end
