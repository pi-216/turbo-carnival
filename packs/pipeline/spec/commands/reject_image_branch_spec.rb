require "rails_helper"

RSpec.describe RejectImageBranch do
  describe "#call" do
    it "marks candidate as rejected" do
      candidate = FactoryBot.create(:image_candidate, status: "active")

      described_class.call!(image_candidate: candidate)

      expect(candidate.reload.status).to eq("rejected")
    end

    it "decrements parent child_count when rejecting a child" do
      parent = FactoryBot.create(:image_candidate)
      child = FactoryBot.create(:image_candidate, parent: parent)

      # Refresh parent to get updated child_count from counter_cache
      parent.reload
      initial_count = parent.child_count

      described_class.call!(image_candidate: child)

      expect(parent.reload.child_count).to eq(initial_count - 1)
    end

    it "does not error when rejecting root candidate" do
      root = FactoryBot.create(:image_candidate, parent: nil)

      expect {
        described_class.call!(image_candidate: root)
      }.not_to raise_error

      expect(root.reload.status).to eq("rejected")
    end
  end
end
