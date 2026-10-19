# frozen_string_literal: true

# PRD 0006 R2 · ticket #83. The Turbo rail asserts the trigger (the head meta),
# never the body marker — the body attribute is inert documentation no Turbo
# version reads. Mirrors spec/requests/layout_spec.rb.
#
# cucumber-rails' World includes Rack::Test::Methods, so `get` is rack-test's
# (it sets `last_response`, not the integration `response`).
Given('I open the application layout') do
  get '/'
end

Then('the layout HEAD carries the turbo morph refresh method') do
  expect(last_response.body).to include('<meta name="turbo-refresh-method" content="morph">')
end
