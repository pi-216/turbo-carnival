# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CaptionGeneration::CaptionMetadata do
  # A stand-in for a GLCommand::Context: only the surface the module touches.
  def result(success:, metadata: nil, messages: [], full_error: nil)
    double('caption result',
           success?: success,
           caption_metadata: metadata,
           errors: double('errors', full_messages: messages),
           full_error_message: full_error)
  end

  describe '.success?' do
    it 'is true only for a successful result' do
      expect(described_class.success?(result(success: true))).to be(true)
      expect(described_class.success?(result(success: false))).to be(false)
    end

    it 'is false for nil (the captioner raised) and for a non-result' do
      expect(described_class.success?(nil)).to be(false)
      expect(described_class.success?(Object.new)).to be(false)
    end
  end

  describe '.for_result' do
    it 'persists the model choice the captioner reported' do
      meta = described_class.for_result(
        result(success: true, metadata: { model: 'gemma3:4b', model_selection: 'preferred_not_resident(gemma3:27b)', timeout: 300 })
      )

      expect(meta[:model]).to eq('gemma3:4b')
      expect(meta[:model_selection]).to eq('preferred_not_resident(gemma3:27b)')
      expect(meta).not_to have_key(:failed)
      expect(meta[:recorded_at]).to be_present
    end

    it 'marks a placeholder caption and keeps the failure reason' do
      meta = described_class.for_result(
        result(success: false, messages: ['Caption generation failed: timed out']),
        placeholder: true
      )

      expect(meta[:placeholder]).to be(true)
      expect(meta[:failed]).to be(true)
      expect(meta[:error]).to eq('Caption generation failed: timed out')
    end

    it 'falls back to the command error message when there are no validation errors' do
      meta = described_class.for_result(result(success: false, full_error: 'boom'), placeholder: true)

      expect(meta[:error]).to eq('boom')
    end

    it 'records a captioner that raised before returning a result' do
      meta = described_class.for_result(nil, placeholder: true)

      expect(meta[:placeholder]).to be(true)
      expect(meta[:failed]).to be(true)
      expect(meta[:error]).to eq('captioner raised before returning a result')
    end

    it 'always returns a Hash (jsonb column) even for an unexpected object' do
      expect(described_class.for_result(Object.new, placeholder: true)).to be_a(Hash)
      expect(described_class.for_result(nil)).to be_a(Hash)
    end
  end
end
