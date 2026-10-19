# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::Assessment, type: :model do
  describe "associations" do
    it { should belong_to(:render).class_name("Attribution::Render") }
  end

  describe "validations" do
    it "requires a render, an assessor and a metric" do
      expect(build(:attribution_assessment, render: nil)).not_to be_valid
      expect(build(:attribution_assessment, assessor_model: nil)).not_to be_valid
      expect(build(:attribution_assessment, assessor_version: nil)).not_to be_valid
      expect(build(:attribution_assessment, metric: nil)).not_to be_valid
    end

    it "rejects a non-numeric value" do
      expect(build(:attribution_assessment, value: "very nice")).not_to be_valid
    end
  end

  describe "keyed to the render and to the assessor" do
    it "holds one row per (render, assessor, metric)" do
      render = create(:attribution_render)
      create(:attribution_assessment, render: render, assessor_model: "auraface",
             assessor_version: "1.0.0", metric: "identity_similarity")

      duplicate = build(:attribution_assessment, render: render, assessor_model: "auraface",
                        assessor_version: "1.0.0", metric: "identity_similarity")

      expect(duplicate).not_to be_valid
    end

    it "lets one assessor record several metrics for one render" do
      render = create(:attribution_render)
      create(:attribution_assessment, render: render, metric: "identity_similarity", value: 0.87)
      create(:attribution_assessment, render: render, metric: "realism", value: 0.61)

      expect(render.reload.assessments.pluck(:metric)).to contain_exactly("identity_similarity", "realism")
    end

    it "keeps two versions of the same assessor apart" do
      render = create(:attribution_render)
      create(:attribution_assessment, render: render, assessor_model: "nsfw", assessor_version: "1.0.0", value: 0.02)

      expect(build(:attribution_assessment, render: render, assessor_model: "nsfw",
                   assessor_version: "2.0.1", value: 0.03)).to be_valid
    end

    it "keys the same metric on different renders independently" do
      create(:attribution_assessment, render: create(:attribution_render), metric: "identity_similarity")

      expect(build(:attribution_assessment, render: create(:attribution_render),
                   metric: "identity_similarity")).to be_valid
    end
  end

  describe "a measurement that did not happen" do
    it "stores NULL rather than a zero" do
      assessment = create(:attribution_assessment, value: nil)

      expect(assessment.reload.value).to be_nil
      expect(assessment.value).not_to eq(0)
    end
  end
end
