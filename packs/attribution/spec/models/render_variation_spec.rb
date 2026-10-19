# frozen_string_literal: true

require "rails_helper"

# #38 criterion 1: two renders differing in exactly one prompt part are queryable as exactly
# that -- the prompt-level analogue of the render-graph leaf diff the experiment lane uses.
RSpec.describe Attribution::Render, type: :model do
  def render_with(parts)
    render = create(:attribution_render)
    parts.each_with_index do |(name, text), position|
      create(:attribution_prompt_part, render: render, name: name, text: text, position: position)
    end
    render
  end

  let(:control) do
    render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom", wardrobe: "cream linen apron")
  end

  describe "#varying_parts" do
    it "names the one part that changed, and nothing else" do
      arm = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom", wardrobe: "silk slip dress")

      expect(arm.varying_parts(control)).to eq([ "wardrobe" ])
      expect(arm.differs_in_exactly_one_part?(control)).to be(true)
    end

    it "names every part that changed when two did" do
      arm = render_with(identity: "sarah1a3", scene: "sunlit bedroom", wardrobe: "silk slip dress")

      expect(arm.varying_parts(control)).to eq([ "identity", "wardrobe" ])
      expect(arm.differs_in_exactly_one_part?(control)).to be(false)
    end

    # An absent part is not the same fact as a written one: silence must not read as agreement.
    # Asserted in BOTH directions, because only the direction where the anchor carries the extra
    # part can tell "absent" from "equal".
    it "treats a part carried by only one render as differing" do
      arm = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom")

      expect(arm.varying_parts(control)).to eq([ "wardrobe" ])
      expect(control.varying_parts(arm)).to eq([ "wardrobe" ])
      expect(arm.differs_in_exactly_one_part?(control)).to be(false)
    end

    it "answers [] for identical prompts" do
      twin = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom", wardrobe: "cream linen apron")

      expect(twin.varying_parts(control)).to eq([])
      expect(twin.differs_in_exactly_one_part?(control)).to be(false)
    end

    # The comparison is symmetric: it is a property of the pair, not of the anchor.
    it "is symmetric" do
      arm = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom", wardrobe: "silk slip dress")

      expect(control.varying_parts(arm)).to eq(arm.varying_parts(control))
    end
  end

  describe ".varying_one_part_from" do
    it "returns the renders that differ in exactly one named part" do
      one_part = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom", wardrobe: "silk slip dress")
      two_parts = render_with(identity: "other", scene: "sunlit bedroom", wardrobe: "silk slip dress")
      missing = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom")
      identical = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom",
                              wardrobe: "cream linen apron")

      found = described_class.varying_one_part_from(control)

      expect(found).to contain_exactly(one_part)
      expect(found).not_to include(two_parts, missing, identical, control)
    end

    it "returns a relation, so it composes as a query" do
      expect(described_class.varying_one_part_from(control)).to be_a(ActiveRecord::Relation)
    end

    # Two differences wearing the shape of one. Without the same-part-count check both of these
    # are admitted, and a one-axis comparison is silently a two-axis one.
    it "excludes a render that differs in one part and is missing another" do
      one_diff_one_missing = render_with(identity: "other", scene: "sunlit bedroom")

      expect(described_class.varying_one_part_from(control)).not_to include(one_diff_one_missing)
    end

    it "excludes a render that carries a part the anchor does not have" do
      narrow = render_with(identity: "sarah1a3, slender", scene: "sunlit bedroom")
      extra = render_with(identity: "other", scene: "sunlit bedroom", wardrobe: "silk slip dress")

      expect(described_class.varying_one_part_from(narrow)).not_to include(extra)
    end

    it "answers nothing for a render with no parts at all" do
      bare = create(:attribution_render)

      expect(described_class.varying_one_part_from(bare)).to be_empty
    end
  end
end
