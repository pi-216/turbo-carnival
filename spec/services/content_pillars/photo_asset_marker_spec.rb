# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# The BYTES half of the synthetic mark (tasks 2.1/2.2 of
# openspec/changes/add-synthetic-provenance).
#
# The served URL is a passthrough to the photo's own file (MediaController#photo
# send_files `servable_file_path`), so the mark has to be IN that file for Meta to
# read it. These specs decode the result the way a reader does -- walk the PNG
# chunks, validate every CRC, compare the pixel payload byte-for-byte -- because
# "the file still opens" is the only property that matters when the file is a
# live, published asset.
RSpec.describe ContentPillars::PhotoAssetMarker do
  around do |example|
    Dir.mktmpdir('asset-marker') do |dir|
      @dir = dir
      example.run
    end
  end
  attr_reader :dir

  def path(name)
    File.join(dir, name)
  end

  def png_chunk(type, data)
    [ data.bytesize ].pack('N') + type.b + data.b + [ Zlib.crc32("#{type}#{data}") ].pack('N')
  end

  def png(width: 2, height: 2)
    raw = (0...height).map { "\x00".b + ("\xFF\x00\x00".b * width) }.join
    ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack('NNC5')
    "\x89PNG\r\n\x1a\n".b +
      png_chunk('IHDR', ihdr) +
      png_chunk('tEXt', "parameters\x00prompt") +
      png_chunk('IDAT', Zlib::Deflate.deflate(raw)) +
      png_chunk('IEND', ''.b)
  end

  # Decode the way a consumer must: every chunk CRC valid, every length
  # consistent. Raises on a truncated or corrupted file -- a silent pass here
  # would mean shipping a broken asset to Instagram.
  def decode_png(bytes)
    expect(bytes[0, 8]).to eq(ContentPillars::PhotoAssetMarker::PNG_SIGNATURE)
    chunks = []
    offset = 8
    while offset < bytes.bytesize
      length = bytes[offset, 4].unpack1('N')
      type = bytes[offset + 4, 4]
      data = bytes[offset + 8, length]
      crc = bytes[offset + 8 + length, 4].unpack1('N')
      expect(crc).to eq(Zlib.crc32("#{type}#{data}")), "bad CRC on #{type}"
      chunks << [ type, data ]
      offset += 12 + length
    end
    chunks
  end

  def jpeg
    # SOI + a small APP0 (JFIF) + EOI: enough structure for a real APP1 insertion.
    "\xFF\xD8".b + "\xFF\xE0".b + [ 16 ].pack('n') + ("JFIF\x00".b + ("\x00".b * 11)) + "\xFF\xD9".b
  end

  describe '.mark!' do
    it 'writes the XMP packet into the PNG bytes, leaving the image data intact' do
      file = path('render.png')
      before = png
      File.binwrite(file, before)

      expect(described_class.mark!(file, { 'source' => 'render' })).to eq(:marked)

      after = File.binread(file)
      chunks = decode_png(after)

      expect(chunks.map(&:first)).to eq(%w[IHDR iTXt tEXt IDAT IEND])
      xmp = chunks.find { |type, _| type == 'iTXt' }.last
      expect(xmp).to include(ContentPillars::PhotoAssetMarker::XMP_KEYWORD)
      expect(xmp).to include('Iptc4xmpExt:DigitalSourceType')
      expect(chunks.find { |type, _| type == 'IDAT' }.last)
        .to eq(decode_png(before).find { |type, _| type == 'IDAT' }.last)
      expect(chunks.find { |type, _| type == 'IHDR' }.last)
        .to eq(decode_png(before).find { |type, _| type == 'IHDR' }.last)
    end

    it 'is readable back out of the bytes as the IPTC digital source type' do
      file = path('render.png')
      File.binwrite(file, png)

      described_class.mark!(file, {})

      expect(described_class.read_digital_source_type(File.binread(file))).to eq('trainedAlgorithmicMedia')
    end

    it 'is idempotent: a second call reports :already_marked and rewrites nothing' do
      file = path('render.png')
      File.binwrite(file, png)
      described_class.mark!(file, {})
      first = File.binread(file)

      expect(described_class.mark!(file, {})).to eq(:already_marked)
      expect(File.binread(file)).to eq(first)
    end

    it 'marks a JPEG with an APP1 segment and keeps the rest of the file' do
      file = path('render.jpg')
      original = jpeg
      File.binwrite(file, original)

      expect(described_class.mark!(file, {})).to eq(:marked)

      after = File.binread(file)
      expect(after[0, 2]).to eq("\xFF\xD8".b)
      expect(after).to include(ContentPillars::PhotoAssetMarker::XMP_APP1_HEADER)
      expect(after).to end_with("\xFF\xD9".b)
      expect(described_class.read_digital_source_type(after)).to eq('trainedAlgorithmicMedia')
      expect(after).to include(original[2..]) # body preserved verbatim after the new segment
    end

    it 'leaves an unsupported container untouched rather than guessing at its format' do
      file = path('render.gif')
      original = 'GIF89a-not-an-image'
      File.binwrite(file, original)

      expect(described_class.mark!(file, {})).to eq(:unsupported)
      expect(File.binread(file)).to eq(original)
    end

    it 'does not rewrite a structurally broken PNG' do
      file = path('broken.png')
      original = "\x89PNG\r\n\x1a\n".b + png_chunk('IHDR', [ 1, 1, 8, 2, 0, 0, 0 ].pack('NNC5')) + 'truncated'
      File.binwrite(file, original)

      expect(described_class.mark!(file, {})).to eq(:unsupported)
      expect(File.binread(file)).to eq(original)
    end

    it 'reports a missing file instead of raising' do
      expect(described_class.mark!(path('nope.png'), {})).to eq(:missing)
    end

    it 'leaves no temp file behind in the served directory' do
      file = path('render.png')
      File.binwrite(file, png)

      described_class.mark!(file, {})

      expect(Dir.children(dir)).to eq([ 'render.png' ])
    end
  end

  describe '.marked?' do
    it 'is false for unmarked bytes and true once marked' do
      file = path('render.png')
      File.binwrite(file, png)

      expect(described_class.marked?(file)).to be(false)
      described_class.mark!(file, {})
      expect(described_class.marked?(file)).to be(true)
    end

    it 'is false for a file that does not exist' do
      expect(described_class.marked?(path('gone.png'))).to be(false)
    end
  end

  # The pre-flight question the ops probe asks before a publish gate can strand
  # the queue. It must be READ-ONLY (the probe runs hourly against the live
  # corpus, which has exactly one copy) and it must agree with `mark!` about what
  # is markable -- both go through `rewrite`.
  describe '.markable' do
    it 'reports :markable for a complete, unmarked PNG and writes nothing' do
      file = path('render.png')
      original = png
      File.binwrite(file, original)

      expect(described_class.markable(file)).to eq(:markable)
      expect(File.binread(file)).to eq(original)
      expect(Dir.children(dir)).to eq([ 'render.png' ])
    end

    it 'reports :markable for a JPEG and :already_marked once marked' do
      file = path('render.jpg')
      File.binwrite(file, jpeg)

      expect(described_class.markable(file)).to eq(:markable)
      described_class.mark!(file, {})
      expect(described_class.markable(file)).to eq(:already_marked)
    end

    it 'agrees with mark! for every container mark! refuses' do
      cases = {
        'render.gif' => 'GIF89a-not-an-image',
        'broken.png' => "\x89PNG\r\n\x1a\n".b +
          png_chunk('IHDR', [ 1, 1, 8, 2, 0, 0, 0 ].pack('NNC5')) + 'truncated'
      }
      cases.each do |name, bytes|
        file = path(name)
        File.binwrite(file, bytes)

        expect(described_class.markable(file)).to eq(:unsupported), "#{name} markable"
        expect(described_class.mark!(file, {})).to eq(:unsupported), "#{name} mark!"
        expect(File.binread(file)).to eq(bytes)
      end
    end

    it 'reports :missing for an absent file' do
      expect(described_class.markable(path('nope.png'))).to eq(:missing)
    end

    it 'reports :unwritable when the containing directory cannot take the temp file' do
      sub = File.join(dir, 'readonly')
      Dir.mkdir(sub)
      file = File.join(sub, 'render.png')
      File.binwrite(file, png)
      File.chmod(0o500, sub)
      begin
        skip 'directory permissions do not bind for this user' if File.writable?(sub)

        expect(described_class.markable(file)).to eq(:unwritable)
        # `mark!` can only discover this by failing -- and it must fail WITHOUT
        # touching the asset.
        expect(described_class.mark!(file, {})).to eq(:error)
        expect(File.binread(file)).to eq(png)
      ensure
        File.chmod(0o700, sub)
      end
    end
  end
end
