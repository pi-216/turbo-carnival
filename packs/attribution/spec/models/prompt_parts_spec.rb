# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::PromptParts, type: :model do
  describe "a part is a name and a text" do
    subject(:parts) do
      described_class.new(identity: "sarah1a3, slender", scene: "sunlit bedroom",
                          wardrobe: "cream linen apron")
    end

    it "keeps the creator's order and answers by name" do
      expect(parts.names).to eq(%w[identity scene wardrobe])
      expect(parts.text_for("scene")).to eq("sunlit bedroom")
      expect(parts.text_for(:wardrobe)).to eq("cream linen apron")
      expect(parts.size).to eq(3)
    end

    it "hands out rows in order, so position is decided once" do
      rows = parts.each_part.map { |name, text, position| [ name, text, position ] }

      expect(rows).to eq([
        [ "identity", "sarah1a3, slender", 0 ],
        [ "scene", "sunlit bedroom", 1 ],
        [ "wardrobe", "cream linen apron", 2 ]
      ])
    end
  end

  describe "the assembled string is DERIVED, never the source" do
    it "assembles from the parts, in order" do
      parts = described_class.new(identity: "A", scene: "B")

      expect(parts.assembled).to eq("A\n\nB")
    end

    # Red line (#38): parsing parts back out of an assembled prompt is a guess. The absence
    # of the constructor IS the enforcement -- there is nothing to call by accident.
    it "has no way to be built from an assembled prompt" do
      expect(described_class).not_to respond_to(:from_string, :parse, :from_assembled)
    end

    it "emits nothing for a part with no text, rather than a placeholder" do
      parts = described_class.new(identity: "A", scene: nil)

      expect(parts.assembled).to eq("A")
    end
  end

  describe "the name is the axis, so the vocabulary is closed" do
    it "refuses a name that is not a known part" do
      expect { described_class.new(lighting: "warm") }
        .to raise_error(ArgumentError, /not a known part/)
    end

    it "refuses the negative, which is a column on the render" do
      expect { described_class.new(negative: "score_5") }
        .to raise_error(ArgumentError, /reserved/)
    end

    it "refuses the same name twice" do
      expect { described_class.new([ [ "scene", "a" ], [ "scene", "b" ] ]) }
        .to raise_error(ArgumentError, /more than once/)
    end

    it "refuses text that is not text" do
      expect { described_class.new(scene: { nested: "nope" }) }
        .to raise_error(ArgumentError, /must carry text/)
    end
  end

  describe ".from" do
    it "passes a PromptParts through unchanged" do
      parts = described_class.new(scene: "A")

      expect(described_class.from(parts)).to equal(parts)
    end

    it "accepts a plain hash" do
      expect(described_class.from({ "scene" => "A" }).text_for(:scene)).to eq("A")
    end
  end

  describe "equality" do
    # Order is presentation (position); equality is the facts.
    it "is the same parts, whatever order they were given in" do
      expect(described_class.new(scene: "A", identity: "B"))
        .to eq(described_class.new(identity: "B", scene: "A"))
    end
  end
end
