# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personas', type: :request do
  describe 'GET /personas' do
    it 'returns success' do
      get personas_path
      expect(response).to have_http_status(:success)
    end

    it 'shows all personas' do
      persona1 = FactoryBot.create(:persona, name: 'Sarah')
      persona2 = FactoryBot.create(:persona, name: 'Emma')

      get personas_path
      expect(response.body).to include('Sarah')
      expect(response.body).to include('Emma')
    end
  end

  describe 'GET /personas/:id' do
    let(:persona) { FactoryBot.create(:persona, name: 'Taylor') }

    it 'returns success' do
      get persona_path(persona)
      expect(response).to have_http_status(:success)
    end

    it 'shows persona details' do
      get persona_path(persona)
      expect(response.body).to include('Taylor')
    end
  end

  describe 'GET /personas/new' do
    it 'returns success' do
      get new_persona_path
      expect(response).to have_http_status(:success)
    end
  end

  describe 'POST /personas' do
    context 'with valid params' do
      it 'creates a persona' do
        expect {
          post personas_path, params: { persona: { name: 'Jordan' } }
        }.to change(Persona, :count).by(1)
      end

      it 'redirects to persona show page' do
        post personas_path, params: { persona: { name: 'Casey' } }
        expect(response).to redirect_to(persona_path(Persona.last))
      end
    end

    context 'with invalid params' do
      it 'does not create a persona' do
        expect {
          post personas_path, params: { persona: { name: '' } }
        }.not_to change(Persona, :count)
      end

      it 'renders new template' do
        post personas_path, params: { persona: { name: '' } }
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'GET /personas/:id/edit' do
    let(:persona) { FactoryBot.create(:persona) }

    it 'returns success' do
      get edit_persona_path(persona)
      expect(response).to have_http_status(:success)
    end
  end

  describe 'PATCH /personas/:id' do
    let(:persona) { FactoryBot.create(:persona, name: 'Alex') }

    context 'with valid params' do
      it 'updates the persona' do
        patch persona_path(persona), params: { persona: { name: 'Alexander' } }
        expect(persona.reload.name).to eq('Alexander')
      end

      it 'redirects to persona show page' do
        patch persona_path(persona), params: { persona: { name: 'Alexander' } }
        expect(response).to redirect_to(persona_path(persona))
      end
    end

    context 'with invalid params' do
      it 'does not update the persona' do
        patch persona_path(persona), params: { persona: { name: '' } }
        expect(persona.reload.name).to eq('Alex')
      end
    end
  end

  describe 'DELETE /personas/:id' do
    let!(:persona) { FactoryBot.create(:persona) }

    it 'destroys the persona' do
      expect {
        delete persona_path(persona)
      }.to change(Persona, :count).by(-1)
    end

    it 'redirects to personas index' do
      delete persona_path(persona)
      expect(response).to redirect_to(personas_path)
    end
  end
end
