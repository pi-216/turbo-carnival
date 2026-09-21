# frozen_string_literal: true

require 'zlib'

module ContentPillars
  # The BYTES half of the synthetic mark
  # (openspec/changes/add-synthetic-provenance, tasks 2.x).
  #
  # `PhotoProvenance` records the mark in the DATABASE; this writes it into the
  # image file itself, so the signal travels with the asset and survives
  # re-upload. That matters because the bytes Meta fetches are the bytes at the
  # photo's own path -- the served URL is a passthrough (MediaController#photo
  # send_file's `servable_file_path`), so embedding at creation is what makes the
  # published asset machine-readable.
  #
  # The carrier is an XMP packet declaring
  # `Iptc4xmpExt:DigitalSourceType = http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia`
  # (the IPTC news code for fully synthetic media, the same vocabulary C2PA and
  # Meta's "AI info" detection read), with `xmpRights:Marked = True`.
  #
  # Formats: PNG (an `iTXt` chunk keyed `XML:com.adobe.xmp`, inserted after IHDR
  # so it precedes IDAT, as the PNG spec requires for XMP) and JPEG (an APP1
  # segment immediately after SOI). Anything else returns `:unsupported` and is
  # left untouched -- guessing at a container format is how you corrupt an asset.
  #
  # `mark!` is idempotent (a second call reports `:already_marked` without
  # rewriting the file) and atomic (temp file in the same directory, then
  # `File.rename`), so a crash mid-write cannot leave a truncated image in the
  # served tree.
  module PhotoAssetMarker
    XMP_KEYWORD = 'XML:com.adobe.xmp'
    # The one substring that is present in the packet itself, in BOTH carriers.
    # `XMP_KEYWORD` is a PNG-only chunk name, so keying presence off it made a
    # marked JPEG read as unmarked (and get a SECOND APP1 segment appended on the
    # next call).
    MARKER = 'Iptc4xmpExt:DigitalSourceType'
    DIGITAL_SOURCE_TYPE = 'trainedAlgorithmicMedia'
    DIGITAL_SOURCE_TYPE_URI = "http://cv.iptc.org/newscodes/digitalsourcetype/#{DIGITAL_SOURCE_TYPE}"
    XMP_APP1_HEADER = "http://ns.adobe.com/xap/1.0/\x00"
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b
    JPEG_SIGNATURE = "\xFF\xD8".b

    module_function

    # Is a machine-readable mark already present in this file's bytes?
    def marked?(path)
      return false unless File.file?(path)

      File.binread(path).include?(MARKER)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      false
    end

    # Write the mark into the asset. Returns one of:
    #   :marked          -- bytes rewritten with the mark
    #   :already_marked  -- the file already carries it (no write)
    #   :missing         -- no such readable file
    #   :unsupported     -- not a PNG/JPEG we are willing to rewrite
    #   :error           -- the rewrite failed (file left untouched)
    def mark!(path, provenance = {})
      return :missing unless path.present? && File.file?(path)

      bytes = File.binread(path)
      return :already_marked if bytes.include?(MARKER)

      packet = xmp_packet(provenance)
      marked =
        if bytes.start_with?(PNG_SIGNATURE)
          with_xmp_png(bytes, packet)
        elsif bytes.start_with?(JPEG_SIGNATURE)
          with_xmp_jpeg(bytes, packet)
        end
      return :unsupported if marked.nil?

      write_atomically(path, marked)
      :marked
    rescue StandardError
      :error
    end

    # Read the declared digital source type back out of the bytes -- the
    # verification the change's task 2.3 demands (read the marker from the
    # bytes that are actually served, not from a local copy we assume matches).
    def read_digital_source_type(bytes)
      return nil unless bytes.to_s.include?(MARKER)

      m = bytes.match(/Iptc4xmpExt:DigitalSourceType="([^"]+)"/)
      return nil unless m

      m[1].to_s.split('/').last
    end

    def xmp_packet(provenance = {})
      attrs = []
      attrs << "Iptc4xmpExt:DigitalSourceType=\"#{DIGITAL_SOURCE_TYPE_URI}\""
      attrs << "xmpRights:WebStatement=\"\""
      attrs << "xmp:Label=\"synthetic\""

      <<~XMP
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
            #{attrs.join("\n      ")}>
           <xmpRights:Marked>True</xmpRights:Marked>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
      XMP
    end

    # --- byte surgery -------------------------------------------------------

    def with_xmp_png(bytes, packet)
      out = +bytes[0, PNG_SIGNATURE.bytesize].b
      offset = PNG_SIGNATURE.bytesize
      seen_ihdr = false
      seen_iend = false

      while offset + 8 <= bytes.bytesize
        length = bytes[offset, 4].unpack1('N')
        type = bytes[offset + 4, 4]
        total = 12 + length
        break if offset + total > bytes.bytesize # truncated file: stop cleanly

        out << bytes[offset, total]
        offset += total

        if !seen_ihdr && type == 'IHDR'
          seen_ihdr = true
          out << itxt_chunk(XMP_KEYWORD, packet)
        end

        seen_iend = true if type == 'IEND'
      end

      # A file must be a COMPLETE PNG to be rewritten: IHDR alone means the walk
      # hit a truncated chunk stream, and rebuilding that would hand Instagram a
      # corrupt asset under the guise of marking it.
      return nil unless seen_ihdr && seen_iend

      out << bytes[offset..].to_s.b # anything after IEND, verbatim
      out
    end

    def itxt_chunk(keyword, text)
      data = +keyword.b
      data << "\x00".b # keyword terminator
      data << "\x00".b # compression flag: uncompressed
      data << "\x00".b # compression method
      data << "\x00".b # language tag (empty)
      data << "\x00".b # translated keyword (empty)
      data << text.b

      [ data.bytesize ].pack('N') + 'iTXt'.b + data + [ Zlib.crc32("iTXt#{data}") ].pack('N')
    end

    def with_xmp_jpeg(bytes, packet)
      payload = +XMP_APP1_HEADER.b + packet.b
      return nil if payload.bytesize + 2 > 0xFFFF

      segment = "\xFF\xE1".b + [ payload.bytesize + 2 ].pack('n') + payload
      bytes[0, 2].b + segment + bytes[2..].to_s.b
    end

    def write_atomically(path, bytes)
      dir = File.dirname(path)
      tmp = File.join(dir, ".#{File.basename(path)}.xmp-#{Process.pid}-#{rand(1_000_000)}.tmp")
      File.binwrite(tmp, bytes)
      File.chmod(File.stat(path).mode & 0o7777, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
