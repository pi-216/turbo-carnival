# frozen_string_literal: true

module Growth
  # ARM the pre-registered discovery pivot.
  #
  # The pivot (ops board, 2026-09-24; openspec/changes/add-reel-discovery-arm)
  # says the account has ZERO non-follower reach -- the platform's own
  # follow_type breakdown answers FOLLOWER-only with no NON_FOLLOWER row and
  # profile_views=0 -- so every content/caption/hashtag/cadence lever is inert by
  # construction and the thesis needs a surface that HAS a discovery step. Reels
  # are that surface, on the same account and API.
  #
  # Everything downstream of the asset was built on 2026-09-24: ReelBuilder (the
  # marked MP4), Instagram::Client#create_reel, MediaController#reel,
  # GeneratePublicReelUrl, and scheduling_posts.reel_path. What was missing is
  # the step that CREATES a reel post at all -- without it the rail has nothing
  # to publish and the pivot sits declared-but-inert, which is exactly what
  # bin/tc_ops.py check_reel_arm_stall watches for.
  #
  # This class owns that step and nothing else: pick renders the harness already
  # produced, compose them into one clip, and record the post. It does NOT
  # publish -- scheduling:post_reels owns that -- so the arm can be built and
  # inspected without an external write.
  #
  # ONE REEL AT A TIME, by guard rather than by hope: it refuses when an
  # unpublished reel post already exists. The arm's first publish is a single
  # reel watched end to end (tasks.md 5.2), and an unbounded asset step is how a
  # bounded rail turns into a burst of external writes.
  class ReelArm
    class Error < StandardError; end

    # 2..8 is ReelBuilder's own range; 4 is long enough to be a story and short
    # enough that one render batch can supply it without reusing an image twice
    # in the same clip.
    SOURCE_PHOTOS = 4
    STRATEGY_NAME = 'reel-discovery-arm'
    REEL_DIR = 'storage/reels'
    DEFAULT_CAPTION = 'A few of my favourite little moments from lately ✨'

    attr_reader :persona

    def initialize(persona:, photo_count: SOURCE_PHOTOS, caption: nil, clock: nil)
      @persona = persona
      @photo_count = photo_count.to_i
      @caption = caption.presence
      @clock = clock || -> { Time.current }
    end

    # -> { post_id:, reel_path:, source_photo_ids:, bytes: }
    def call
      raise Error, 'a persona is required to arm the reel rail' if persona.blank?

      guard_no_pending_reel!

      sources = source_photos
      path = build_clip(sources)
      post = create_post(path)

      {
        post_id: post.id,
        reel_path: path,
        source_photo_ids: sources.map(&:id),
        bytes: File.size(path)
      }
    end

    # Refuse to build a second reel while one is queued but unpublished. Without
    # this the asset step is a fixed-cadence requester that never observes grant
    # state -- the queue-growth failure the ops board already carries a rule for
    # (a queue that grows while the rail is idle is a failure signal, not a
    # backlog).
    def guard_no_pending_reel!
      pending = Scheduling::Post
                .where(persona: persona, status: %w[draft scheduled])
                .where.not(reel_path: nil)
      return if pending.none?

      ids = pending.pluck(:id).join(', ')
      raise Error, "a reel post is already queued and unpublished (post #{ids}); publish it (scheduling:post_reels) before arming another"
    end

    # Renders the harness already produced, newest first, that are still readable.
    # Reusing published renders is deliberate: the clip is a montage of the
    # persona's own recent looks, and a reel post carries NO photo, so nothing is
    # consumed and the still queue is untouched.
    def source_photos
      # Memoised: #hashtags_for reads the same set, and a second query could
      # return a different batch (renders land continuously) -- which would tag
      # the clip with hashtags derived from an image that is not in it.
      @source_photos ||= begin
        candidates = ContentPillars::Photo
                     .where(persona: persona)
                     .where.not(path: nil)
                     .order(created_at: :desc)
                     .limit(@photo_count * 3)

        servable = candidates.select do |photo|
          file = photo.servable_file_path
          file.present? && File.file?(file)
        end

        chosen = servable.first(@photo_count)
        if chosen.size < Growth::ReelBuilder::MIN_PHOTOS
          raise Error, "need at least #{Growth::ReelBuilder::MIN_PHOTOS} readable renders for #{persona.name}, " \
                       "found #{chosen.size} (of #{candidates.size} candidates)"
        end

        chosen
      end
    end

    def build_clip(sources)
      files = sources.map(&:servable_file_path)
      path = File.join(Rails.root.to_s, REEL_DIR, "reel-#{persona.id}-#{@clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}.mp4")

      Growth::ReelBuilder.build(photos: files, output_path: path)

      # Read the writer's output back rather than trusting the builder's return:
      # an unmarked asset must never reach the rail (GeneratePublicReelUrl would
      # refuse it, but failing here names the real cause).
      unless Growth::ReelBuilder.marked?(path)
        raise Error, "built clip #{path} carries no machine-readable synthetic mark"
      end

      path
    end

    def create_post(reel_path)
      now = @clock.call

      Scheduling::Post.create!(
        persona: persona,
        # Deliberately NO photo: the published media is the composed clip, and a
        # reel that joined a photo would enter Growth::GateRead#cohort_size -- the
        # still-based cohort the pivot was pre-registered against.
        photo: nil,
        reel_path: reel_path,
        caption: @caption || DEFAULT_CAPTION,
        hashtags: hashtags_for,
        status: 'scheduled',
        # Due NOW: the reel rail publishes on its next tick. A future slot would
        # also make this post count toward Growth::CadenceEngine's queue target,
        # which is a STILL-queue measurement.
        scheduled_at: now,
        optimal_time_calculated: now,
        strategy_name: STRATEGY_NAME
      )
    end

    def hashtags_for
      ContentStrategy::HashtagEngine.generate(photo: source_photos.first, pillar: nil, count: 10)
    rescue StandardError => e
      Rails.logger.warn("reel arm hashtag generation failed: #{e.class} - #{e.message}")
      []
    end
  end
end
