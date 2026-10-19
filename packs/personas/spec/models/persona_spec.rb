# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Persona, type: :model do
  describe 'validations' do
    it { should validate_presence_of(:name) }
    it { should validate_uniqueness_of(:name) }
  end

  describe '#caption_config' do
    let(:persona) { FactoryBot.create(:persona) }

    it 'returns nil when not set' do
      expect(persona.caption_config).to be_nil
    end

    it 'can be set with a hash' do
      persona.caption_config = { tone: 'warm', style: 'conversational' }
      persona.save!
      persona.reload

      expect(persona.caption_config).to be_a(Personas::CaptionConfig)
      expect(persona.caption_config.tone).to eq('warm')
      expect(persona.caption_config.style).to eq('conversational')
    end
  end

  describe '#hashtag_strategy' do
    let(:persona) { FactoryBot.create(:persona) }

    it 'returns nil when not set' do
      expect(persona.hashtag_strategy).to be_nil
    end

    it 'can be set with a hash' do
      persona.hashtag_strategy = { max_tags: 10, brand_tags: [ 'test' ] }
      persona.save!
      persona.reload

      expect(persona.hashtag_strategy).to be_a(Personas::HashtagStrategy)
      expect(persona.hashtag_strategy.max_tags).to eq(10)
    end
  end
end
