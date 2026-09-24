# frozen_string_literal: true

# Serves photo image bytes from local/NAS files (no B2 required).
# Used by Instagram publishing (public URL) and by the caption vision pipeline.
class MediaController < ApplicationController
  def photo
    photo = ContentPillars::Photo.find(params[:id])

    # WITHHELD RENDERS ARE NOT PUBLICLY DOWNLOADABLE (2026-09-23).
    #
    # This endpoint is fronted by the Cloudflare tunnel and takes a SEQUENTIAL
    # id, so /media/photos/1..N is enumerable -- while the only consumer that
    # needs these bytes over the wire is the publisher, which mints the URL from
    # `post.photo` at publish time (Scheduling::Commands::GeneratePublicPhotoUrl,
    # reached from schedule_post.rb and scheduled_posting.rake). Captioning does
    # NOT use this URL: ImageEncoder base64s `servable_file_path` locally. So the
    # withhold is a rule the serving layer can own outright: serve a photo only
    # while a post still references it.
    #
    # WHAT THIS CLOSES: when a post is PURGED (13 of them, action=nsfw_purge,
    # scores 0.93-0.9999) the post ROW is deleted and the Photo row + bytes stay
    # -- so an image deliberately withheld from the feed remained one guessable
    # URL away from anyone. Measured 2026-09-23: `GET /media/photos/241` -> 200
    # for a purged photo, and the same held for the 51 renders of this persona
    # that never became a post (38 unlinked + 13 purged).
    #
    # ONE-SIDED ON PURPOSE: a photo with ANY post is untouched -- and that is
    # every photo the publishing path can ask for, because the URL is built from
    # a post that already exists -- so this cannot break a publish, while a
    # render no post references has no publishing consumer to lose.
    unless Scheduling::Post.where(photo_id: photo.id).exists?
      head :not_found
      return
    end

    file = photo.servable_file_path

    unless file
      head :not_found
      return
    end

    send_file file,
              type: "image/png",
              disposition: "inline",
              cache_control: "public, max-age=86400"
  end

  # Serves a REELS post's MP4 -- the `video_url` Instagram fetches for the
  # discovery-surface pivot (ops decision 2026-09-24).
  #
  # WHY IT LIVES HERE. Instagram::Client#create_reel needs a publicly fetchable
  # video URL, and the rail had none: #photo serves `image/png` for a Photo and
  # nothing served a video. Without this, the pivot's machinery was built but
  # uncallable.
  #
  # THE WITHHOLD RULE IS THE STILL PATH'S, and it is even tighter here: the id
  # IS a post id, so bytes are served exactly while the post that owns them
  # exists. A purged/rejected reel post stops being downloadable the moment its
  # row goes -- the same one-sided rule #photo applies, with nothing extra to
  # enumerate (there is no separate video row to walk).
  #
  # The bytes are the file at `post.reel_path`, which Growth::ReelBuilder wrote
  # with the IPTC synthetic mark embedded in the container metadata, so the asset
  # Meta fetches carries the same machine-readable disclosure as the stills.
  def reel
    post = Scheduling::Post.find_by(id: params[:id])

    file = post&.reel_path
    unless file.present? && File.file?(file)
      head :not_found
      return
    end

    send_file file,
              type: "video/mp4",
              disposition: "inline",
              cache_control: "public, max-age=86400"
  end
end
