# frozen_string_literal: true

FactoryBot.define do
  factory :growth_goal, class: 'Growth::Goal' do
    association :persona
    instagram_handle { 'test_handle' }
    target_followers { 1000 }
    start_followers { 0 }
    posts_per_day { 1 }
    max_posts_per_day { 3 }
    hashtag_count { 10 }
    status { 'active' }
  end
end
