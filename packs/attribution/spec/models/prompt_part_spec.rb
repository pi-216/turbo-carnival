# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::PromptPart, type: :model do
  describe "associations" do
    it { should belong_to(:render).class_name("Attribution::Render") }
  end

  describe "validations" do
    it "requires a name and a render" do
      expect(build(:attribution_prompt_part, name: nil)).not_to be_valid
      expect(build(:attribution_prompt_part, render: nil)).not_to be_valid
    end

    it "allows one part per name per render" do
      render = create(:attribution_render)
      create(:attribution_prompt_part, render: render, name: "scene")

      duplicate = build(:attribution_prompt_part, render: render, name: "scene")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "allows the same part name on different renders" do
      create(:attribution_prompt_part, render: create(:attribution_render), name: "scene")

      expect(build(:attribution_prompt_part, render: create(:attribution_render), name: "scene")).to be_valid
    end
  end

  describe "one home per fact" do
    # The negative is a single scalar per render, so it is a render column.
    # Accepting it as a part as well would give one fact two homes.
    it "refuses the negative as a part name" do
      part = build(:attribution_prompt_part, name: "negative")

      expect(part).not_to be_valid
      expect(part.errors[:name].join).to match(/negative/)
    end
  end

  describe "addressability" do
    it "lets two renders differing in exactly one part be told apart" do
      shared = "sunlit bedroom, 50mm lens"
      first = create(:attribution_render)
      second = create(:attribution_render)
      [ first, second ].each do |render|
        create(:attribution_prompt_part, render: render, name: "scene", text: shared)
      end
      create(:attribution_prompt_part, render: first, name: "wardrobe", text: "cream linen apron")
      create(:attribution_prompt_part, render: second, name: "wardrobe", text: "silk slip dress")

      differing = Attribution::PromptPart.where(name: "wardrobe")

      expect(differing.pluck(:render_id)).to contain_exactly(first.id, second.id)
      expect(differing.pluck(:text)).to contain_exactly("cream linen apron", "silk slip dress")
      expect(Attribution::PromptPart.where(name: "scene").pluck(:text).uniq).to eq([ shared ])
    end

    it "records a stable digest of the part text so a part can change without a text diff" do
      text = "silk slip dress"
      part = create(:attribution_prompt_part, text: text)

      expect(part.text_sha256).to eq(Digest::SHA256.hexdigest(text))
    end

    it "stores a part with no text without inventing one" do
      part = create(:attribution_prompt_part, text: nil)

      expect(part.text).to be_nil
      expect(part.text_sha256).to be_nil
    end
  end
end
