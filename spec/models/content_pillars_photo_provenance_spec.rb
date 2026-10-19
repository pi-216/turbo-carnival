# frozen_string_literal: true

require 'rails_helper'

# The single choke point where a completed render becomes a Photo
# (openspec/changes/add-synthetic-provenance, tasks 1.1 + 1.3).
#
# Both render producers used to create the row themselves
# (Growth::ContentGenerator for the sync path, Growth::RenderSalvage for the
# recovery path), so anything the row must carry had to be remembered twice.
RSpec.describe ContentPillars::Photo, type: :model do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let(:pipeline) { create(:pipeline) }
  let(:run) do
    create(:pipeline_run, pipeline: pipeline, persona: persona, content_pillar: pillar,
                          prompt: 'a beach scene', variables: { 'seed' => 7000 })
  end
  let(:path) { "/tmp/provenance-spec-#{SecureRandom.hex(6)}.png" }

  describe '.import_render' do
    it 'marks the photo synthetic and records the provenance of its render' do
      photo = described_class.import_render(path: path, persona: persona, content_pillar: pillar, run: run)

      expect(photo.synthetic).to be(true)
      expect(photo.provenance['digital_source_type']).to eq('trainedAlgorithmicMedia')
      expect(photo.provenance['source']).to eq('render')
      expect(photo.provenance['embedded']).to be(false)
      expect(photo.provenance['run_id']).to eq(run.id)
      expect(photo.provenance['seed']).to eq(7000)
    end

    it 'is idempotent on path and keeps the first mark' do
      first = described_class.import_render(path: path, persona: persona, content_pillar: pillar, run: run)
      second = described_class.import_render(path: path, persona: persona, content_pillar: pillar, run: run)

      expect(second.id).to eq(first.id)
      expect(described_class.where(path: path).count).to eq(1)
      expect(second.provenance['run_id']).to eq(run.id)
    end

    it 'never defaults a photo to human origin: an unmarked row reads as unknown' do
      photo = described_class.create!(persona: persona, path: path, content_pillar: pillar)

      expect(photo.synthetic).to be_nil
      expect(described_class.where(synthetic: nil).exists?(id: photo.id)).to be(true)
    end
  end
end
