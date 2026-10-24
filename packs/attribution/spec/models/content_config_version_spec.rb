# frozen_string_literal: true

require "rails_helper"

# #40 criterion 2: "editing a version is impossible by construction -- a change produces a new
# row". Each layer of that claim is asserted here separately, because the layers catch
# different things: the derived digest makes identity structural, `#readonly?` closes every
# ActiveRecord write path, and the database trigger is the only thing that sees `update_all`
# and raw SQL.
RSpec.describe Attribution::ContentConfigVersion, type: :model do
  let(:parts) do
    Attribution::PromptParts.new(
      identity: "sarah1a3, slender, freckles",
      scene: "sunlit bedroom, three-quarter front view",
      wardrobe: "short cream linen apron"
    )
  end

  let(:pins) do
    { prompt_parts: parts, wardrobe_level: 2, checkpoint: "CRPv18_PM25.safetensors",
      negative_prompt: "score_5, worst quality" }
  end

  def record(**overrides)
    result = Attribution::RecordContentConfigVersion.call(**pins, **overrides)

    raise result.full_error_message unless result.success?

    result.version
  end

  describe "associations" do
    it { should have_many(:renders).class_name("Attribution::Render").dependent(:restrict_with_error) }
    it { should belong_to(:content_pillar).optional }
    it { should belong_to(:pipeline_step).optional }
  end

  describe "the pins are rows and columns, not a blob" do
    it "keeps the pinned axes as columns" do
      expect(described_class.column_names)
        .to include("checkpoint", "negative_prompt", "workflow_sha256", "wardrobe_level", "digest")
    end

    # Same guard the render carries (#37): a jsonb column would be a blob wearing a schema,
    # and the whole point of the spine is that these axes are groupable and joinable.
    it "has no jsonb column at all" do
      jsonb = described_class.columns.select { |column| column.sql_type == "jsonb" }

      expect(jsonb.map(&:name)).to be_empty
    end

    it "stores the prompt as named part rows, in position order" do
      version = record

      expect(version.prompt_parts.order(:position).pluck(:name)).to eq(%w[identity scene wardrobe])
      expect(version.prompt_parts.find_by(name: "scene").text)
        .to eq("sunlit bedroom, three-quarter front view")
    end

    it "stores the LoRA set with strengths and the on/off flag" do
      version = record(loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.8, enabled: true },
                                { name: "pony/underboob.safetensors", layer: "base", strength: 0.75, enabled: false } ])

      expect(version.loras.pluck(:layer, :name, :strength, :enabled))
        .to eq([ [ "base", "pony/sarah1a3.safetensors", 0.8, true ],
                 [ "base", "pony/underboob.safetensors", 0.75, false ] ])
    end

    it "leaves an axis nobody pinned as NULL, never as a default" do
      version = Attribution::RecordContentConfigVersion.call(prompt_parts: parts).version

      expect(version.checkpoint).to be_nil
      expect(version.negative_prompt).to be_nil
      expect(version.workflow_sha256).to be_nil
      expect(version.wardrobe_level).to be_nil
      expect(version.workflow_path).to be_nil
    end
  end

  describe "the digest is derived from the pins, never authored" do
    it "recomputes the stored digest from the row's own columns and rows" do
      version = record

      expect(version.digest).to match(Attribution::ContentConfigVersion::DIGEST_FORMAT)
      expect(version.recomputed_digest).to eq(version.digest)
      expect(version).to be_consistent
    end

    it "produces the same digest for the same pins recorded twice" do
      expect(record.digest).to eq(record.digest)
    end

    # One example per pinned axis, because a digest that ignores an axis silently merges two
    # different configs into one version -- the exact failure this column exists to prevent.
    # The overrides are lambdas so `parts` (a `let`) is only read inside an example.
    changed_pins = {
      "checkpoint" => ->(_parts) { { checkpoint: "a-different.safetensors" } },
      "negative_prompt" => ->(_parts) { { negative_prompt: "no nipples, areola" } },
      "wardrobe_level" => ->(_parts) { { wardrobe_level: 5 } },
      "prompt parts" => lambda { |parts|
        { prompt_parts: Attribution::PromptParts.new(parts.to_h.merge("wardrobe" => "silk slip dress")) }
      },
      "LoRA strength" => lambda { |_parts|
        { loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.61, enabled: true } ] }
      },
      "LoRA on/off flag" => lambda { |_parts|
        { loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.8, enabled: false } ] }
      }
    }

    changed_pins.each do |axis, overrides|
      it "changes the digest when the #{axis} changes" do
        expect(record(**overrides.call(parts)).digest).not_to eq(record.digest)
      end
    end

    it "changes the digest when the pillar changes" do
      pillar = create(:content_pillar, persona: create(:persona))

      expect(record(content_pillar: pillar).digest).not_to eq(record.digest)
    end

    # Provenance is recorded but is NOT identity: the sha is what the graph IS, the path is
    # where it was read from -- the same rule `assets.sha256` vs `assets.path` follows.
    it "ignores the workflow path, which is provenance and not content" do
      other_path = { workflow_path: "comfy_workflows/elsewhere/copied.json" }

      expect(record(**other_path).digest).to eq(record.digest)
    end

    # Position is for reading, not for identity: naming the same parts in a different ORDER is
    # the same config.
    it "ignores the order the parts were given in" do
      reordered = Attribution::PromptParts.new(
        scene: "sunlit bedroom, three-quarter front view",
        identity: "sarah1a3, slender, freckles",
        wardrobe: "short cream linen apron"
      )

      expect(record(prompt_parts: reordered).digest).to eq(record.digest)
    end
  end

  describe "immutability" do
    let!(:version) { record }

    it "is readonly once persisted" do
      expect(version).to be_readonly
      expect(described_class.new).not_to be_readonly
    end

    it "refuses an edit through the model, whatever the path" do
      expect { version.update!(checkpoint: "edited.safetensors") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { version.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses to be deleted out from under the pins and renders it covers" do
      expect(version.destroy).to be(false)
      expect(described_class.exists?(version.id)).to be(true)
    end

    # The next four examples each stand alone ON PURPOSE: a database refusal aborts the
    # surrounding transaction, so a second assertion in the same example would report
    # `InFailedSqlTransaction` instead of the refusal it is meant to prove.

    # `update_all` is the bypass the model layer cannot see: it builds SQL directly, skipping
    # `readonly?` AND every callback. Only the database can refuse it.
    it "refuses an edit through update_all, which the model layer cannot see" do
      expect { described_class.where(id: version.id).update_all(checkpoint: "edited.safetensors") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    # A mutable child row is an edit to the version wearing a costume: the digest names the
    # children, so changing one without a new version would make the digest a lie.
    it "refuses an edit to its prompt parts through update_all" do
      expect { version.prompt_parts.update_all(text: "edited") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "refuses an edit to its LoRA set through update_all" do
      with_loras = record(loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.8, enabled: true } ])

      expect { with_loras.loras.update_all(strength: 0.1) }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "refuses raw SQL, so a later migration cannot rewrite a version in place" do
      expect do
        ActiveRecord::Base.connection.execute(
          "UPDATE content_config_versions SET checkpoint = 'edited.safetensors' WHERE id = #{version.id}"
        )
      end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "refuses a delete, so a version cannot take its renders' attribution with it" do
      expect do
        ActiveRecord::Base.connection.execute("DELETE FROM content_config_versions WHERE id = #{version.id}")
      end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    # With nothing referencing it, the association-level refusal has nothing to say, so the
    # model layer is the one that answers. (The DELETE example above is the database's answer,
    # for the paths the model never sees.)
    it "refuses a delete of an unreferenced version at the model layer too" do
      bare = create(:attribution_content_config_version)

      expect { bare.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    # The whole ticket in one example: a change does not edit anything, it adds a row.
    it "produces a NEW row when a pin changes, leaving the original untouched" do
      original = record
      changed = record(checkpoint: "a-different.safetensors")

      expect(changed.id).not_to eq(original.id)
      expect(described_class.count).to eq(2)
      expect(original.reload.checkpoint).to eq("CRPv18_PM25.safetensors")
      expect(original.recomputed_digest).to eq(original.digest)
    end
  end
end
