# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# The render mount has moved twice (an original /mnt/essdee/ComfyUI, then
# /mnt/fscache/essdee/ComfyUI -- itself a symlink into the NAS), so a photo's
# `path` records WHICH MOUNT WAS CURRENT when it was imported, not where its
# bytes live now. `servable_file_path` must therefore resolve a photo by its
# path RELATIVE to a ComfyUI-output root, against roots that actually exist.
#
# This used to fall back to '/mnt/synology-home/backup/essdee/ComfyUI', which is
# not a mount at all, and knew only the original prefix -- so 101 photos with
# intact bytes in the NAS mirror read as "no bytes anywhere" (measured
# 2026-09-20) and were written off as permanently unpostable.
RSpec.describe ContentPillars::Photo, type: :model do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let(:mirror) { Dir.mktmpdir('photo-mirror') }

  before { stub_const('ContentPillars::Photo::MIRROR_ROOTS', [ mirror ]) }
  after { FileUtils.remove_entry(mirror) }

  def photo(path)
    described_class.create!(persona: persona, path: path, content_pillar: pillar)
  end

  def mirror_file(rel)
    full = File.join(mirror, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, 'png-bytes')
    full
  end

  describe '#servable_file_path' do
    it 'returns the recorded path when the bytes are still there' do
      real = mirror_file('direct.png')

      expect(photo(real).servable_file_path).to eq(real)
    end

    it 'resolves a photo imported from the ORIGINAL mount through the mirror' do
      expected = mirror_file('sarah1a3/fashion/962260888105743/image_00002_.png')

      p = photo('/mnt/essdee/ComfyUI/output/sarah1a3/fashion/962260888105743/image_00002_.png')

      expect(p.servable_file_path).to eq(expected)
    end

    it 'resolves a photo imported from the CURRENT mount through the mirror' do
      expected = mirror_file('gen-1789000000_00001_.png')

      p = photo('/mnt/fscache/essdee/ComfyUI/output/gen-1789000000_00001_.png')

      expect(p.servable_file_path).to eq(expected)
    end

    it 'resolves through an output/ subdirectory of the mirror' do
      expected = mirror_file('output/nested.png')

      expect(photo('/mnt/essdee/ComfyUI/output/nested.png').servable_file_path).to eq(expected)
    end

    it 'refuses a bare filename, whose identity the mirror cannot establish' do
      # The mirror holds thousands of files sharing generic names
      # (image_00002_.png), so a first-match glob can serve a DIFFERENT photo's
      # bytes. Unresolvable by name => nil, never a guess.
      mirror_file('image_00002_.png')

      expect(photo('image_00002_.png').servable_file_path).to be_nil
    end

    it 'returns nil when neither the path nor the mirror has the bytes' do
      expect(photo('/mnt/essdee/ComfyUI/output/gone.png').servable_file_path).to be_nil
    end

    it 'counts a mirror-resolved photo as servable bytes' do
      mirror_file('recovered.png')

      expect(photo('/mnt/essdee/ComfyUI/output/recovered.png').servable_bytes?).to be(true)
    end
  end
end
