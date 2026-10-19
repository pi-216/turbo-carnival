# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::Lora, type: :model do
  describe "associations" do
    it { should belong_to(:render).class_name("Attribution::Render") }
  end

  describe "validations" do
    it "requires a name and a layer" do
      expect(build(:attribution_lora, name: nil)).not_to be_valid
      expect(build(:attribution_lora, layer: nil)).not_to be_valid
    end

    it "rejects a non-numeric strength" do
      expect(build(:attribution_lora, strength: "strong")).not_to be_valid
    end

    it "allows the same lora in two layers with different strengths" do
      render = create(:attribution_render)
      create(:attribution_lora, render: render, layer: "base", name: "shared.safetensors", strength: 0.8)

      expect(build(:attribution_lora, render: render, layer: "face_inpaint",
                   name: "shared.safetensors", strength: 1.0)).to be_valid
    end

    it "refuses the same lora twice inside one layer" do
      render = create(:attribution_render)
      create(:attribution_lora, render: render, layer: "base", name: "pony/sk1nny.safetensors")

      duplicate = build(:attribution_lora, render: render, layer: "base", name: "pony/sk1nny.safetensors")

      expect(duplicate).not_to be_valid
    end
  end

  describe "an off slot is a recorded fact, not an omission" do
    # Measured in this repo: an off LoRA's strength is INERT. Recording both the
    # strength and the flag is what distinguishes "off at 0.75" from "absent".
    it "records a disabled lora with its strength" do
      lora = create(:attribution_lora, enabled: false, strength: 0.75)

      expect(lora.reload.enabled).to be(false)
      expect(lora.strength).to eq(0.75)
    end

    it "reads an unrecorded strength or flag as NULL, never as 0 or false" do
      lora = create(:attribution_lora, strength: nil, enabled: nil)

      expect(lora.reload.strength).to be_nil
      expect(lora.enabled).to be_nil
      expect(lora.strength).not_to eq(0)
    end
  end
end
