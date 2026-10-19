# frozen_string_literal: true

FactoryBot.define do
  factory :persona do
    sequence(:name) { |n| "Persona #{n}" }

    trait :with_caption_config do
      after(:build) do |persona|
        persona.caption_config = { tone: "warm", style: "conversational" }
      end
    end

    trait :with_hashtag_strategy do
      after(:build) do |persona|
        persona.hashtag_strategy = { max_tags: 10, brand_tags: [ "test" ] }
      end
    end
  end
end
