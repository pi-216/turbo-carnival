# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'tmpdir'

# The DISCOVERY ARM's asset step (ops decision 2026-09-24).
#
# Root cause this covers: the account's own insights report zero non-follower
# reach (FOLLOWER=6, NON_FOLLOWER absent, profile_views=0), so the thesis's
# publish -> discovery -> follows mechanism has no discovery step and every
# content/caption/hashtag/cadence lever is inert. Reels are the one organic
# surface with non-follower distribution and publish on the same account/API.
#
# Two properties are load-bearing and are asserted here rather than assumed:
#   1. the clip is a VALID Reels asset -- 9:16, H.264/yuv420p, MP4, and the
#      duration arithmetic matches the inputs (an xfade overlap shortens it);
#   2. the machine-readable synthetic mark is IN THE BYTES (THESIS red line),
#      read back with ffprobe, not trusted from the builder's own return.
RSpec.describe Growth::ReelBuilder do
  def ffmpeg?
    @ffmpeg ||= system('bash -lc "command -v ffmpeg >/dev/null"')
  end

  def ffprobe_json(path, entries)
    out, = Open3.capture2e('ffprobe', '-v', 'error', '-of', 'json',
                           '-show_entries', entries, path)
    JSON.parse(out)
  end

  # Two real image files with the render geometry (816x1024), produced by the
  # same toolchain the builder uses -- no fixture binaries in the repo.
  def pngs(dir, count: 2)
    Array.new(count) do |i|
      path = File.join(dir, "still_#{i}.png")
      system('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi',
             '-i', "color=c=0x#{format('%06x', (i + 1) * 0x336699)}:s=816x1024",
             '-frames:v', '1', path) or raise "could not generate #{path}"
      path
    end
  end

  around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

  describe 'input validation' do
    it 'refuses fewer than two photos' do
      expect do
        described_class.new(photos: [ '/nope.png' ], output_path: File.join(@dir, 'o.mp4')).call
      end.to raise_error(described_class::Error, /needs 2\.\.8 photos/)
    end

    it 'refuses unreadable photo files rather than producing a silent short clip' do
      expect do
        described_class.new(photos: [ '/nope.png', '/also-nope.png' ],
                            output_path: File.join(@dir, 'o.mp4')).call
      end.to raise_error(described_class::Error, /not readable/)
    end

    it 'refuses a blank output path' do
      expect do
        described_class.new(photos: [ 'a.png', 'b.png' ], output_path: '').call
      end.to raise_error(described_class::Error, /output_path is required/)
    end

    it 'refuses a per-photo duration at or below the crossfade length' do
      expect do
        described_class.new(photos: [ 'a.png', 'b.png' ], output_path: File.join(@dir, 'o.mp4'),
                            seconds_per_photo: 0.4).call
      end.to raise_error(described_class::Error, /seconds_per_photo/)
    end
  end

  describe '.marked?' do
    it 'is false for a file that does not exist, and for a file without the mark' do
      expect(described_class.marked?(File.join(@dir, 'missing.mp4'))).to be(false)
      plain = File.join(@dir, 'plain.bin')
      File.binwrite(plain, 'no marker here')
      expect(described_class.marked?(plain)).to be(false)
    end
  end

  describe 'building a real clip', :integration do
    before { skip 'ffmpeg not installed' unless ffmpeg? }

    it 'produces a valid 9:16 H.264 MP4 whose duration matches the inputs' do
      out = File.join(@dir, 'reel.mp4')
      described_class.build(photos: pngs(@dir, count: 3), output_path: out)

      info = ffprobe_json(out, 'stream=codec_name,width,height,pix_fmt,duration:format=duration,format_name')
      stream = info['streams'].first
      expect(stream['codec_name']).to eq('h264')
      expect(stream['width']).to eq(described_class::WIDTH)
      expect(stream['height']).to eq(described_class::HEIGHT)
      expect(stream['pix_fmt']).to eq('yuv420p')
      expect(info['format']['format_name']).to include('mp4')
      # 3 photos x 3s, minus one crossfade overlap per join.
      expect(info['format']['duration'].to_f).to be_within(0.2).of(3 * 3.0 - 2 * 0.5)
    end

    it 'embeds the IPTC synthetic mark in the container, readable from the bytes' do
      out = File.join(@dir, 'reel.mp4')
      described_class.build(photos: pngs(@dir, count: 2), output_path: out)

      tags = ffprobe_json(out, 'format_tags')['format']['tags']
      expect(tags[described_class::MARKER]).to include('trainedAlgorithmicMedia')
      expect(described_class.marked?(out)).to be(true)
      expect(File.binread(out)).to include('trainedAlgorithmicMedia')
    end

    it 'streams the moov atom first, so Instagram can begin fetching immediately' do
      out = File.join(@dir, 'reel.mp4')
      described_class.build(photos: pngs(@dir, count: 2), output_path: out)

      # faststart: the moov box must precede mdat, so a fetcher can read the
      # index without pulling the whole file.
      bytes = File.binread(out)
      expect(bytes.index('moov')).to be_a(Integer)
      expect(bytes.index('moov')).to be < bytes.index('mdat')
    end
  end
end
