# frozen_string_literal: true

namespace :scheduling do
  desc 'Post any scheduled posts that are due now'
  task post_scheduled: :environment do
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "  Scheduled Post Runner"
    puts "  Time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts ""

    now = Time.current

    draft_posts = Scheduling::Post
      .where(status: 'draft')
      .where.not(optimal_time_calculated: nil)
      .where('optimal_time_calculated <= ?', now)

    scheduled_status_posts = Scheduling::Post
      .where(status: 'scheduled')
      .where.not(scheduled_at: nil)
      .where('scheduled_at <= ?', now)

    all_posts = (draft_posts.to_a + scheduled_status_posts.to_a).sort_by do |post|
      post.optimal_time_calculated || post.scheduled_at
    end

    if all_posts.empty?
      puts "No posts scheduled for posting at this time."
      puts ""

      next_draft = Scheduling::Post
        .where(status: 'draft')
        .where.not(optimal_time_calculated: nil)
        .where('optimal_time_calculated > ?', now)
        .order(:optimal_time_calculated)
        .first

      next_scheduled = Scheduling::Post
        .where(status: 'scheduled')
        .where.not(scheduled_at: nil)
        .where('scheduled_at > ?', now)
        .order(:scheduled_at)
        .first

      next_posts = [next_draft, next_scheduled].compact
      next_post = next_posts.min_by { |p| p.optimal_time_calculated || p.scheduled_at }

      if next_post
        scheduled_time = next_post.optimal_time_calculated || next_post.scheduled_at
        time_until = ((scheduled_time - now) / 3600).round(1)
        puts "Next scheduled post:"
        puts "  Photo ID: #{next_post.photo_id}"
        puts "  Scheduled: #{scheduled_time.strftime('%Y-%m-%d %H:%M %Z')}"
        puts "  Time until: #{time_until} hours"
      else
        puts "No posts scheduled."
        puts ""
        puts "💡 Tip: Create scheduled posts with:"
        puts "   bundle exec rails scheduling:create_scheduled_post[persona_name]"
      end

      puts ""
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      exit 0
    end

    puts "Found #{all_posts.count} post(s) ready to publish:"
    puts ""

    all_posts.each do |post|
      scheduled_time = post.optimal_time_calculated || post.scheduled_at
      puts "📸 Post ID: #{post.id}"
      puts "   Photo ID: #{post.photo_id}"
      puts "   Scheduled: #{scheduled_time.strftime('%Y-%m-%d %H:%M %Z')}"
      puts ""

      begin
        post.start_posting!

        public_url_result = Scheduling::Commands::GeneratePublicPhotoUrl.call!(photo: post.photo)

        if public_url_result.success?
          # Include the post's hashtags in what we actually publish. The column has
          # always existed (scheduling_posts.hashtags, jsonb) and a HashtagEngine has
          # always been able to fill it, but nothing ever read it at send time: every
          # one of the 197 posted items went out with ZERO hashtags, which is the
          # single biggest discoverability lever for a small account.
          published_caption = [post.caption, Array(post.hashtags).join(" ")]
                                .map { |part| part.to_s.strip }
                                .reject(&:empty?)
                                .join("\n\n")

          instagram_result = Scheduling::Commands::SendPostToInstagram.call!(
            public_photo_url: public_url_result.public_photo_url,
            caption: published_caption,
            persona: post.persona
          )

          if instagram_result.success?
            post.update!(
              provider_post_id: instagram_result.instagram_post_id,
              posted_at: Time.current
            )
            post.mark_as_posted!

            puts "   ✅ Posted successfully!"
            puts "   Instagram ID: #{instagram_result.instagram_post_id}"
          else
            post.mark_as_failed!
            puts "   ❌ Instagram posting failed: #{instagram_result.errors.join(', ')}"
            Rails.logger.error("Instagram posting failed for post #{post.id}: #{instagram_result.errors}")
          end
        else
          post.mark_as_failed!
          puts "   ❌ URL generation failed: #{public_url_result.errors}"
          Rails.logger.error("URL generation failed for post #{post.id}: #{public_url_result.errors}")
        end
      rescue StandardError => e
        post.mark_as_failed! if post.status != 'draft'
        puts "   ❌ Error: #{e.message}"
        Rails.logger.error("Scheduled posting error for post #{post.id}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end

      puts ""
    end

    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "Completed at: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  end
end
