FactoryBot.define do
  factory :pipeline_step do
    association :pipeline
    sequence(:name) { |n| "Step #{n}" }
    sequence(:order)
    comfy_workflow_json { '{"workflow": "test"}' }
    max_children { ENV.fetch("MAX_CHILDREN_PER_NODE", "3").to_i }
  end
end
