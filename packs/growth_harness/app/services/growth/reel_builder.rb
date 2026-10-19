# frozen_string_literal: true

require 'open3'
require 'shellwords'

module Growth
  # The DISCOVERY ARM's asset step, decided on the ops board 2026-09-24 and
  # pre-registered before any build.
  #
  # WHY THIS EXISTS. The pre-registered GO/PIVOT/KILL gate names
  # `distribution/reach` as its pivot candidate. Measured 2026-09-24, that number
  # is not a proxy but a statement from the platform: the account's own insights
  # answer `reach` with `breakdown=follow_type`, and the split is
  # FOLLOWER=6 / NON_FOLLOWER (absent) -- i.e. ZERO non-follower reach, with
  # profile_views=0 behind it. Nothing outside the follower list is being shown
  # these posts at all. That makes the thesis's mechanism (publish -> discovery ->
  # follows) miss its middle step entirely, and it makes every content, caption,
  # hashtag and cadence lever measurably inert: they cannot move a number that is
  # zero by construction on the surface they publish to.
  #
  # Reels/motion is the one organic Instagram surface with non-follower
  # distribution, it is publishable on the SAME account and API (media_type=REELS)
  # with no credential or platform change -- so it is a build here, not an ask on
  # a human. Its success metric is the already-collected
  # `growth_snapshots.non_follower_reach` (>0 == discovery), NOT engagement:
  # engagement is the wrong read for an account with no discovery.
  #
  # This class owns only the BYTES. It turns renders the harness already produces
  # into a short vertical clip. It does not publish, does not choose a photo, and
  # does not touch the scheduler.
  #
  # PROVENANCE IS NOT OPTIONAL (THESIS red line: "never publish a render without a
  # machine-readable synthetic mark"). The mark goes into the container's own
  # metadata with the same IPTC vocabulary the still path uses, and
  # `Growth::ReelBuilder.marked?` reads it back out of the bytes -- the same
  # read-back-the-writer's-output discipline as
  # ContentPillars::PhotoAssetMarker.marked?.
  class ReelBuilder
    # Instagram Reels: 9:16, 1080x1920, H.264/yuv420p in MP4, 3s..15min. The
    # renders are 816x1024 (4:5), so the frame is PADDED onto a blurred,
    # cover-scaled copy of itself rather than cropped -- a centre crop of a 4:5
    # portrait to 9:16 removes ~29% of the width and is how a head gets cut off.
    WIDTH  = 1080
    HEIGHT = 1920
    FPS    = 30
    # Seconds each photo occupies on screen, and the length of the crossfade
    # between neighbours. The overlap means the finished clip is
    # `n * per - (n - 1) * fade` seconds long, not `n * per`.
    SECONDS_PER_PHOTO = 3.0
    CROSSFADE_S = 0.5
    # A Reel is a story, not a slideshow: bounding the inputs also bounds the
    # ffmpeg filtergraph, which grows linearly in the number of inputs.
    MIN_PHOTOS = 2
    MAX_PHOTOS = 8
    ZOOM = "min(zoom+0.0007,1.15)"

    DIGITAL_SOURCE_TYPE = 'trainedAlgorithmicMedia'
    MARKER = 'Iptc4xmpExt:DigitalSourceType'

    class Error < StandardError; end

    def initialize(photos:, output_path:, seconds_per_photo: SECONDS_PER_PHOTO)
      @photos = Array(photos)
      @output_path = output_path.to_s
      @seconds_per_photo = seconds_per_photo.to_f
    end

    # Build the clip. Returns the output path. Raises Growth::ReelBuilder::Error
    # with ffmpeg's own stderr tail on failure -- a silent nil here would let a
    # broken reel become a lost publishing slot.
    def call
      validate!
      run_ffmpeg
      @output_path
    end

    def self.build(...)
      new(...).call
    end

    # Does this file carry the machine-readable synthetic mark? Read from the
    # bytes, never from the builder's own return value.
    def self.marked?(path)
      return false unless path.present? && File.file?(path)

      File.binread(path).include?(MARKER)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      false
    end

    private

    def validate!
      raise Error, "a reel needs #{MIN_PHOTOS}..#{MAX_PHOTOS} photos, got #{@photos.size}" \
        unless @photos.size.between?(MIN_PHOTOS, MAX_PHOTOS)
      raise Error, 'output_path is required' if @output_path.blank?
      raise Error, "seconds_per_photo must be > crossfade (#{CROSSFADE_S}s)" \
        unless @seconds_per_photo > CROSSFADE_S + 0.5

      missing = @photos.reject { |p| File.file?(p.to_s) }
      raise Error, "photo file(s) not readable: #{missing.join(', ')}" if missing.any?

      raise Error, "ffmpeg not on PATH" if ffmpeg_path.nil?

      FileUtils.mkdir_p(File.dirname(@output_path))
    end

    def run_ffmpeg
      out, err, status = Open3.capture3(*ffmpeg_argv)
      return if status.success? && File.file?(@output_path) && File.size(@output_path) > 0

      raise Error, "ffmpeg failed (#{status.exitstatus}): #{err.to_s.lines.last(6).join.strip}"
    rescue Errno::ENOENT => e
      raise Error, "ffmpeg could not be executed: #{e.message}"
    end

    def ffmpeg_path
      @ffmpeg_path ||= ENV['FFMPEG_BIN'].presence || begin
        out, = Open3.capture2e('bash', '-lc', 'command -v ffmpeg')
        out.strip.presence
      rescue StandardError
        nil
      end
    end

    # A still is a ONE-FRAME video, and zoompan is what expands it: `d` frames
    # out per input frame at `fps`, so each photo becomes exactly
    # `seconds_per_photo` of clip. Looping the input first (`-loop 1 -t N`) and
    # THEN feeding it to zoompan multiplies the two -- 75 input frames x 90
    # output frames each -- which is how this produced a 4-minute "3-second"
    # segment on the first attempt.
    def inputs
      @photos.flat_map { |p| [ '-i', p.to_s ] }
    end

    def filtergraph
      n = @photos.size
      chains = (0...n).map do |i|
        "[#{i}:v]" \
          "split=2[bg#{i}][fg#{i}];" \
          "[bg#{i}]scale=#{WIDTH}:#{HEIGHT}:force_original_aspect_ratio=increase," \
          "crop=#{WIDTH}:#{HEIGHT},gblur=sigma=40[bgb#{i}];" \
          "[fg#{i}]scale=#{WIDTH}:#{HEIGHT}:force_original_aspect_ratio=decrease[fgs#{i}];" \
          "[bgb#{i}][fgs#{i}]overlay=(W-w)/2:(H-h)/2," \
          "zoompan=z='#{ZOOM}':d=#{frames_per_photo}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':" \
          "s=#{WIDTH}x#{HEIGHT}:fps=#{FPS},setsar=1,format=yuv420p[v#{i}]"
      end

      # Chain the crossfades: each xfade's offset is where THAT segment starts
      # overlapping, which is one photo-length minus one fade per step.
      xfades = (1...n).map do |i|
        prev = i == 1 ? '[v0]' : "[x#{i - 1}]"
        offset = (i * (@seconds_per_photo - CROSSFADE_S)).round(3)
        out = "[x#{i}]"
        "#{prev}[v#{i}]xfade=transition=fade:duration=#{CROSSFADE_S}:offset=#{offset}#{out}"
      end

      label = n == 1 ? '[v0]' : "[x#{n - 1}]"
      (chains + xfades + [ "#{label}null[out]" ]).join(';')
    end

    def frames_per_photo
      (@seconds_per_photo * FPS).round
    end

    def ffmpeg_argv
      [
        ffmpeg_path, '-y', '-hide_banner', '-loglevel', 'error',
        *inputs,
        '-filter_complex', filtergraph,
        '-map', '[out]',
        '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
        '-crf', '20', '-preset', 'medium',
        # `faststart` for streaming and `use_metadata_tags` so the arbitrary
        # marker key survives into the container's udta/---- atom. ONE -movflags
        # with both: a second -movflags REPLACES the first, so writing them on
        # separate lines silently drops faststart.
        '-movflags', '+faststart+use_metadata_tags',
        '-metadata', "#{MARKER}=http://cv.iptc.org/newscodes/digitalsourcetype/#{DIGITAL_SOURCE_TYPE}",
        '-metadata', 'description=Synthetic media: AI-generated persona render',
        @output_path
      ]
    end
  end
end
