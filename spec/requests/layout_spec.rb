# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Application layout", type: :request do
  describe "Turbo morph refresh contract" do
    before do
      get "/"
    end

    it "declares the morph refresh method in the head meta" do
      expect(response).to have_http_status(:success)
      expect(response.body).to include(
        '<meta name="turbo-refresh-method" content="morph">'
      )
    end

    it "marks the body as the morph target" do
      expect(response.body).to include('data-turbo-morph')
      expect(response.body).to match(/<body[^>]*data-turbo-morph/)
    end
  end
end
