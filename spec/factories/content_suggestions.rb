FactoryBot.define do
  factory :content_suggestion do
    gap_analysis { nil }
    content_pillar { nil }
    title { "MyString" }
    description { "MyText" }
    prompt_data { {} }
    status { "pending" }
    used_at { nil }
  end
end
