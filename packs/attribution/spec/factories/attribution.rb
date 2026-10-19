# frozen_string_literal: true

# Factories for the attribution spine (packs/attribution).
#
# Loaded by packs-rails' FactoryBot integration, which appends every pack's
# `spec/factories` to the definition file paths -- so these are available to the
# root `spec/` suite as well as to the pack's own specs.
FactoryBot.define do
  factory :attribution_asset, class: "Attribution::Asset" do
    sequence(:sha256) { |n| format("%064x", n) }
    kind { "image" }
    path { "/tmp/attribution-assets/#{SecureRandom.hex(8)}.png" }
    byte_size { 1_234_567 }
    width { 832 }
    height { 1216 }
  end

  factory :attribution_render, class: "Attribution::Render" do
    seed { 20_261_019 }
    checkpoint { "CRPv18_PM25.safetensors" }
    sampler { "euler_ancestral" }
    scheduler { "karras" }
    steps { 125 }
    cfg { 5.5 }
    denoise { 1.0 }
    width { 832 }
    height { 1216 }
    negative_prompt { "score_5, worst quality, low quality" }
    workflow_sha256 { Digest::SHA256.hexdigest("turbo_one_step_v2/step1_generate.json") }
    workflow_path { "comfy_workflows/turbo_one_step_v2/step1_generate.json" }
    produced_at { Time.current }

    trait :with_asset do
      association :asset, factory: :attribution_asset
    end
  end

  factory :attribution_prompt_part, class: "Attribution::PromptPart" do
    association :render, factory: :attribution_render
    name { "identity" }
    text { "sarah1a3, slender, freckles" }
    position { 0 }
  end

  factory :attribution_lora, class: "Attribution::Lora" do
    association :render, factory: :attribution_render
    layer { "base" }
    name { "pony/sarah1a3_pony_pornmaster_v1.safetensors" }
    strength { 0.8 }
    enabled { true }
    position { 0 }
  end

  factory :attribution_assessment, class: "Attribution::Assessment" do
    association :render, factory: :attribution_render
    assessor_model { "auraface" }
    assessor_version { "1.0.0" }
    metric { "identity_similarity" }
    value { 0.87 }
    assessed_at { Time.current }
  end
end
