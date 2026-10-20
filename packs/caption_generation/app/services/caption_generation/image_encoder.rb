# frozen_string_literal: true

require 'base64'

module CaptionGeneration
  # Photo -> base64 bytes for a vision model, in ONE place.
  #
  # Extracted from CaptionGeneration::VisionGenerator (2026-09-21) when the
  # persona age gate needed to send the same render to the same model. Two
  # copies of this logic would drift on exactly the two details that matter and
  # are invisible from outside: which SOURCE wins (the photo's local/NAS file,
  # falling back to the ActiveStorage blob -- every growth render is path-only,
  # so the blob is almost never the answer) and the DOWNSCALE (a vision seat's
  # cost grows fast with image size; the cap is what keeps a call fast).
  #
  # OUTPUT FORMAT (ticket #103): always JPEG. The brain is reached through an
  # OpenAI-compatible endpoint where the image rides a `data:image/jpeg` URL, so
  # the label must match the bytes. JPEG is also the right container for a
  # photographic render (no alpha to preserve), and it keeps the base64 payload
  # small enough to send to a 128k-context seat without wasting it on the frame.
  module ImageEncoder
    MAX_DIMENSION = 1024
    MAX_PIXELS = MAX_DIMENSION * MAX_DIMENSION

    module_function

    # Can this photo be encoded at all? The guard must match what raw_bytes can
    # ACTUALLY do, so it accepts either source; a photo with neither is the only
    # one refused.
    def readable?(photo)
      photo.present? && (photo.image.attached? || photo.servable_file_path.present?)
    end

    def encode_base64(photo)
      Base64.strict_encode64(downscaled(raw_bytes(photo)))
    end

    # Prefer the local/NAS file (no B2). Falls back to the ActiveStorage blob.
    def raw_bytes(photo)
      local = photo.servable_file_path
      return File.binread(local) if local
      raise ArgumentError, 'Photo has no readable image bytes' unless photo.image.attached?

      photo.image.download
    end

    def downscaled(data)
      require 'mini_magick'
      image = MiniMagick::Image.read(data)
      pixels = image.width * image.height
      image = image.resize("#{MAX_DIMENSION}x#{MAX_DIMENSION}>") if pixels && pixels > MAX_PIXELS
      # Always emit JPEG (see the class comment): the data-URL label is jpeg, and
      # a photographic render does not need the source's container.
      image.to_blob('JPEG')
    rescue StandardError
      # If downscale fails (no imagemagick, odd format), send original
      data
    end
  end
end
