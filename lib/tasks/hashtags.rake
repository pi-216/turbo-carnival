# frozen_string_literal: true

namespace :hashtags do
  desc 'Fill hashtags on queued posts that have none ' \
       '(dry-run; APPLY=1 to write, INCLUDE_DUE=1 to include already-due posts)'
  task backfill_queued: :environment do
    dry_run = ENV['APPLY'] != '1'
    include_due = ENV['INCLUDE_DUE'] == '1'
    results = ContentStrategy::QueuedHashtagBackfill.call(dry_run: dry_run,
                                                          include_due: include_due)

    if results.empty?
      puts 'No unpublished post is missing hashtags.'
      next
    end

    puts "#{results.size} unpublished post(s) have no hashtags:"
    results.each do |r|
      line = +"  ##{r.post_id} #{r.outcome}"
      line << " (#{r.error})" if r.error
      line << " -> #{Array(r.hashtags).join(' ')}" if Array(r.hashtags).any?
      puts line
    end

    if dry_run
      puts ''
      puts 'DRY RUN -- nothing written. Hashtags are part of what the public ' \
           'account says, so the write is opt-in: re-run with APPLY=1 to fill them.'
    else
      puts ''
      puts "filled #{results.count { |r| r.outcome == :filled }}, " \
           "unfilled #{results.count { |r| r.outcome == :unfilled }}, " \
           "failed #{results.count { |r| r.outcome == :failed }}"
    end
  end
end
