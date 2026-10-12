# frozen_string_literal: true

namespace :scheduling do
  # Publish due REELS posts -- the reel rail.
  #
  # WHY THIS IS A SEPARATE TASK, not a branch inside post_scheduled. The still
  # rail resolves `post.photo` at every step (GeneratePublicPhotoUrl -> the
  # image container), while a REELS post carries `reel_path` and NO photo by
  # design (its published media is the composed clip, and keeping it out of the
  # photo join keeps it out of Growth::GateRead#cohort_size -- the still-based
  # cohort the pivot was pre-registered against). scheduling:post_scheduled
  # therefore EXCLUDES reel rows explicitly and only COUNTS them, so that a reel
  # waiting for its own rail is visible rather than silently absent. This task is
  # that rail.
  #
  # Bounded by LIMIT (default 1) per tick on purpose: the arm's first publish is
  # a single reel watched end to end, and a cap means a mistake in the arm's
  # asset step can never turn into a burst of publishes. Publishing more is
  # LIMIT=N, a deliberate act.
  #
  # Failures are recorded on the row with record_failure! (so the ops board's
  # silent-failure check can read WHY a slot was lost) and never re-published
  # blindly: `failed` is terminal in the state machine.
  desc 'Publish any due REELS posts (LIMIT=N, default 1). The still rail excludes reels; this is the reel rail.'
  task post_reels: :environment do
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "  Reels Post Runner (discovery arm)"
    puts "  Time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts ""

    now = Time.current
    limit = (ENV['LIMIT'] || '1').to_i
    limit = 1 if limit < 1

    due = Scheduling::Post
          .where(status: %w[draft scheduled])
          .where.not(reel_path: nil)
          .where('(optimal_time_calculated <= :now) OR (scheduled_at <= :now)', now: now)
          .order(Arel.sql('COALESCE(optimal_time_calculated, scheduled_at) ASC'))
          .limit(limit)
          .to_a

    if due.empty?
      pending = Scheduling::Post.where(status: %w[draft scheduled]).where.not(reel_path: nil).count
      puts 'No REELS posts are due.'
      puts "  (#{pending} reel post(s) queued for a future slot)" if pending.positive?
      puts ""
      # `next`, not `exit 0`: this task is one non-fatal step inside
      # bin/scheduled_posting.sh, and a task that ends its process is a task that
      # can end its caller.
      next
    end

    puts "Found #{due.size} due REELS post(s) to publish:"
    puts ""

    due.each do |post|
      slot = post.optimal_time_calculated || post.scheduled_at
      puts "🎬 Reel post ID: #{post.id}"
      puts "   Reel: #{post.reel_path}"
      puts "   Slot: #{slot&.strftime('%Y-%m-%d %H:%M %Z')}"
      puts ""

      begin
        post.start_posting!

        url_result = Scheduling::Commands::GeneratePublicReelUrl.call(post: post)

        if url_result.success?
          # Same caption/hashtag composition as the still rail: the column has
          # always existed and the publisher is the only path that knows the
          # post is about to become public.
          published_caption = [ post.caption, Array(post.hashtags).join(" ") ]
                              .map { |part| part.to_s.strip }
                              .reject(&:empty?)
                              .join("\n\n")

          reel_result = Scheduling::Commands::SendReelToInstagram.call!(
            public_reel_url: url_result.public_reel_url,
            caption: published_caption,
            persona: post.persona
          )

          if reel_result.success?
            post.update!(
              provider_post_id: reel_result.instagram_post_id,
              posted_at: Time.current
            )
            post.mark_as_posted!

            puts "   ✅ Reel published!"
            puts "   Instagram ID: #{reel_result.instagram_post_id}"
          else
            post.record_failure!("instagram_reel: #{reel_result.errors.join(', ')}")
            puts "   ❌ Reel publish failed: #{reel_result.errors.join(', ')}"
            Rails.logger.error("Instagram reel publish failed for post #{post.id}: #{reel_result.errors}")
          end
        else
          post.record_failure!("reel_url_generation: #{url_result.errors.join(', ')}")
          puts "   ❌ Reel URL generation failed: #{url_result.errors}"
          Rails.logger.error("Reel URL generation failed for post #{post.id}: #{url_result.errors}")
        end
      rescue StandardError => e
        post.record_failure!("#{e.class}: #{e.message}") if post.status != 'draft'
        puts "   ❌ Error: #{e.message}"
        Rails.logger.error("Reels posting error for post #{post.id}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end

      puts ""
    end

    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "Completed at: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  end
end
