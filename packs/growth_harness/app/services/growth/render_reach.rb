# frozen_string_literal: true

module Growth
  # What each render earned: reach and views grouped by the render that produced the
  # post's image. #39 criterion 2 -- the spine IS the mapping, so there is no
  # hand-kept render->post table anywhere.
  #
  # The chain, every hop a real column and none of them parsed:
  #   scheduling_posts.photo_id -> photos.image_candidate_id
  #     -> image_candidates.id -> renders.image_candidate_id
  #
  # Reels carry no photo, so they are ABSENT from this read rather than attributed to
  # a guess, and a render with no published post is absent too -- not a zero row.
  # SUM() over an all-NULL group answers NULL (SQL), which is the red line again: a
  # render whose posts have no reach yet has UNKNOWN reach, not 0.
  #
  # Measured 2026-10-19: `photos.image_candidate_id` is unique and
  # `scheduling_posts[photo_id, persona_id]` is unique, so today the chain is 1:1 and
  # a group holds one post. The COUNT/SUM are kept because they are what the question
  # means ("what did this render earn") and they stay correct if a candidate is ever
  # carried by more than one post.
  #
  # The two hand-written joins are deliberate. Declaring `ImageCandidate#render` and
  # `ImageCandidate#photos` would make packs/pipeline reference packs/attribution and
  # packs/content_pillars, while attribution already depends on pipeline -- that is a
  # cycle. So the edge is declared once, on the render side
  # (`Attribution::Render#image_candidate`), and traversed from there.
  class RenderReach
    Row = Struct.new(:render_id, :checkpoint, :seed, :post_count, :reach, :views,
                     keyword_init: true)

    def self.call
      rows = Attribution::Render
             .joins(:image_candidate)
             .joins("JOIN photos ON photos.image_candidate_id = image_candidates.id")
             .joins("JOIN scheduling_posts ON scheduling_posts.photo_id = photos.id")
             .where("scheduling_posts.status" => "posted")
             .group("renders.id", "renders.checkpoint", "renders.seed")
             .select(
               "renders.id AS render_id",
               "renders.checkpoint AS checkpoint",
               "renders.seed AS seed",
               "COUNT(scheduling_posts.id) AS post_count",
               "SUM(scheduling_posts.reach) AS reach",
               "SUM(scheduling_posts.views) AS views"
             )

      rows.map do |row|
        Row.new(render_id: row.render_id, checkpoint: row.checkpoint, seed: row.seed,
                post_count: row.post_count, reach: row.reach, views: row.views)
      end
    end
  end
end
