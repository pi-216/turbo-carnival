require "rails_helper"

RSpec.describe JobOrchestrationConfig do
  describe ".max_children_per_node" do
    it "returns default value of 2" do
      expect(described_class.max_children_per_node).to eq(3)
    end

    it "reads from environment variable" do
      ClimateControl.modify MAX_CHILDREN_PER_NODE: "7" do
        expect(described_class.max_children_per_node).to eq(7)
      end
    end
  end

  describe ".target_leaf_nodes" do
    it "returns default value of 10" do
      expect(described_class.target_leaf_nodes).to eq(10)
    end

    it "reads from environment variable" do
      ClimateControl.modify TARGET_LEAF_NODES: "15" do
        expect(described_class.target_leaf_nodes).to eq(15)
      end
    end
  end
end
