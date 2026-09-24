# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CreatePersona do
  describe '.call' do
    context 'with valid parameters' do
      it 'creates a persona' do
        expect {
          result = described_class.call(name: 'Sarah')
          expect(result.success?).to be true
        }.to change(Persona, :count).by(1)
      end

      it 'returns the persona in context' do
        result = described_class.call(name: 'Emma')
        expect(result.persona).to be_a(Persona)
        expect(result.persona.name).to eq('Emma')
      end
    end

    context 'with invalid parameters' do
      it 'fails when name is blank' do
        result = described_class.call(name: '')
        expect(result.success?).to be false
        expect(result.full_error_message).to include("can't be blank")
      end

      it 'fails when name is duplicate' do
        FactoryBot.create(:persona, name: 'Taylor')
        result = described_class.call(name: 'Taylor')
        expect(result.success?).to be false
        expect(result.full_error_message).to include('taken')
      end
    end

    describe '#rollback' do
      it 'destroys created persona on rollback' do
        result = described_class.call(name: 'Alex')
        persona_id = result.persona.id

        result.persona.destroy
        expect(Persona.find_by(id: persona_id)).to be_nil
      end
    end
  end
end
