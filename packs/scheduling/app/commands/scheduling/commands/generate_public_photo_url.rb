# frozen_string_literal: true

module Scheduling
  module Commands
    # Resolves the URL Instagram will fetch, and -- since tasks 3.1/3.2 of
    # openspec/changes/add-synthetic-provenance -- is the fail-closed gate that
    # keeps an UNMARKED synthetic asset from reaching Instagram::Client#create_post.
    #
    # It is the right place for that gate because it is the last step of
    # SchedulePost before SendPostToInstagram, and because the bytes Meta reads are
    # the bytes this URL resolves to: the tunnel URL is a passthrough to the
    # photo's own file (MediaController#photo send_file's `servable_file_path`),
    # so checking the file here checks exactly what will be published.
    #
    # Order matters: assert -> mark in flight when missing -> block only when the
    # mark is still absent. A photo that can be marked publishes normally, so the
    # gate does not consume the queue; only a genuinely unmarkable asset stops,
    # consistent with the existing NSFW and realism gates.
    class GeneratePublicPhotoUrl < GLCommand::Callable
      requires photo: ContentPillars::Photo
      returns public_photo_url: String

      def call
        # Preferred: serve from this app over the tunnel (no B2). Requires the
        # photo to have a servable local/NAS file and a configured public base.
        if app_public_base.present? && photo.servable?
          return unless synthetic_mark_ok?(photo.servable_file_path)

          context.public_photo_url = "#{app_public_base}/media/photos/#{photo.id}"
          return
        end

        # Fallback: ActiveStorage URL (B2) when the photo has an attached blob.
        # The bytes there are not ours to mark, so the gate can only ask whether
        # the mark is ALREADY recorded as embedded; an unmarked asset falls
        # through to the same block. Measured 2026-09-21: 0 of the 17 live
        # scheduled/draft posts resolve here (all 337 render files are local), so
        # this branch is legacy, not the daily path.
        unless photo.image.attached?
          stop_and_fail!('Photo has no servable file and no attached image')
          return
        end

        if photo.provenance.to_h['embedded'] == true
          context.public_photo_url = photo.image.url
          return
        end

        stop_and_fail!(unmarked_message('its bytes are served from ActiveStorage, which this gate cannot mark'))
      end

      private

      # True when the file the URL will serve carries a machine-readable synthetic
      # mark. Marks in flight when it does not, and reads the bytes back rather
      # than trusting the writer's own verdict.
      def synthetic_mark_ok?(file)
        return true if ContentPillars::PhotoAssetMarker.marked?(file)

        verdict = photo.mark_synthetic_asset!
        if %i[marked already_marked].include?(verdict) &&
           ContentPillars::PhotoAssetMarker.marked?(photo.servable_file_path)
          Rails.logger.info("[provenance] marked synthetic asset for photo #{photo.id} at publish time (#{verdict})")
          return true
        end

        stop_and_fail!(unmarked_message("embedding returned #{verdict}"))
        false
      end

      def unmarked_message(why)
        "Photo #{photo.id} carries no machine-readable synthetic mark, so publishing it would " \
          "present synthetic media as photography: #{why}. " \
          'Run `rails photos:embed_provenance` (PHOTO_ID=' + photo.id.to_s + ') to mark it.'
      end

      def app_public_base
        ENV['TURBO_CARNIVAL_PUBLIC_URL'].presence ||
          Rails.application.credentials.dig(:app, :public_url).to_s.presence
      end
    end
  end
end
