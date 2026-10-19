# frozen_string_literal: true

FactoryBot.define do
  factory :content_pillar do
    association :persona
    name { "Content Pillar #{rand(1000)}" }
    description { "A test content pillar for #{persona&.name || 'a persona'}" }
  end
end
