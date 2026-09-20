# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelinePromptSafety do
  # Mirrors the live turbo-one-step graph shape: the sampler's negative input
  # points STRAIGHT at a CLIPTextEncode carrying the prompt text, while the
  # positive input points at a CLIPTextEncode whose text comes through an
  # indirection chain (PreviewAny -> StringConcatenate -> Text Multiline). The
  # negative node is titled "CLIP Text Encode (Prompt)", so no title can tell the
  # two apart -- only the graph can.
  def workflow(negative:, positive:, extra: {})
    {
      '60' => {
        'class_type' => 'CLIPTextEncode',
        '_meta' => { 'title' => 'CLIP Text Encode (Prompt)' },
        'inputs' => { 'text' => %w[89 0], 'clip' => %w[97 0] }
      },
      '79' => {
        'class_type' => 'CLIPTextEncode',
        '_meta' => { 'title' => 'CLIP Text Encode (Prompt)' },
        'inputs' => { 'text' => negative, 'clip' => %w[97 0] }
      },
      '88' => { 'class_type' => 'Text Multiline', 'inputs' => { 'text' => positive } },
      '89' => { 'class_type' => 'PreviewAny', 'inputs' => { 'source' => %w[73 0] } },
      '73' => {
        'class_type' => 'StringConcatenate',
        'inputs' => { 'string_a' => %w[111 0], 'string_b' => %w[88 0] }
      },
      '111' => { 'class_type' => 'Text Multiline', 'inputs' => { 'text' => '{{prompt}}' } },
      '96' => {
        'class_type' => 'KSampler',
        'inputs' => { 'positive' => %w[60 0], 'negative' => %w[79 0], 'seed' => %w[55 0] }
      },
      '55' => { 'class_type' => 'Seed', 'inputs' => { 'seed' => 12_345 } }
    }.merge(extra)
  end

  describe '.sanitize_workflow' do
    it 'strips adult-suppressing tokens from the sampler NEGATIVE prompt and leaves the list clean' do
      wf = workflow(
        negative: 'score_5, score_4, worst quality, low quality, long neck, adult, mature_face, sunken_eyes',
        positive: 'score_9, score_8_up, sarah1a3, slender, freckles'
      )

      out, changes = described_class.sanitize_workflow(wf)

      expect(out['79']['inputs']['text'])
        .to eq('score_5, score_4, worst quality, low quality, long neck, sunken_eyes')
      expect(out['79']['inputs']['text']).not_to match(/adult|mature_face/)
      expect(changes.map(&:kind)).to include(:adult_suppression_removed)
    end

    it 'does NOT strip adult tokens from the POSITIVE prompt (only the safety floor is enforced)' do
      wf = workflow(
        negative: 'worst quality, low quality',
        positive: 'portrait of an adult woman in her thirties, sarah1a3'
      )

      out, = described_class.sanitize_workflow(wf)

      expect(out['88']['inputs']['text']).to eq('portrait of an adult woman in her thirties, sarah1a3')
    end

    it 'rewrites a minor direction anywhere in the workflow, including an LLM system instruction' do
      wf = workflow(
        negative: 'worst quality, low quality',
        positive: 'sarah1a3, slender',
        extra: {
          '96x' => {
            'class_type' => 'OllamaGenerateV2',
            'inputs' => {
              'system' => 'Change the prompt so the resulting image will be that of a white, ' \
                          'Caucasian young teenager. Only return the new prompt.'
            }
          }
        }
      )

      out, changes = described_class.sanitize_workflow(wf)

      expect(out['96x']['inputs']['system'])
        .to eq('Change the prompt so the resulting image will be that of a white, Caucasian adult. ' \
               'Only return the new prompt.')
      expect(out['96x']['inputs']['system']).not_to match(/teenager/)
      expect(changes.map(&:node_id)).to include('96x')
    end

    it 'treats a node carrying negative boilerplate as a negative prompt even with no sampler input' do
      wf = workflow(
        negative: 'worst quality, low quality',
        positive: 'sarah1a3',
        extra: {
          '77' => {
            'class_type' => 'CLIPTextEncode',
            'inputs' => { 'text' => 'worst quality, low quality, adult, mature_face' }
          }
        }
      )

      out, = described_class.sanitize_workflow(wf)

      expect(out['77']['inputs']['text']).to eq('worst quality, low quality')
    end

    it 'leaves a clean workflow untouched and reports no changes' do
      wf = workflow(
        negative: 'worst quality, low quality, bad anatomy',
        positive: 'sarah1a3, slender, freckles, fully clothed'
      )

      out, changes = described_class.sanitize_workflow(wf)

      expect(changes).to be_empty
      expect(out).to eq(wf)
    end

    it 'does not touch non-text values' do
      wf = workflow(negative: 'worst quality, adult', positive: 'sarah1a3')

      out, = described_class.sanitize_workflow(wf)

      expect(out['55']['inputs']['seed']).to eq(12_345)
      expect(out['96']['inputs']['positive']).to eq(%w[60 0])
    end

    it 'is a no-op on a non-hash workflow' do
      expect(described_class.sanitize_workflow(nil)).to eq([ nil, [] ])
    end
  end
end
