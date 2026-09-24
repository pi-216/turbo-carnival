# frozen_string_literal: true

namespace :captions do
  desc "Re-generate captions for queued posts still carrying the placeholder " \
       "(dry-run; APPLY=1 to write, INCLUDE_DUE=1 to include already-due posts)"
  task refresh_placeholders: :environment do
    dry_run = ENV["APPLY"] != "1"
    include_due = ENV["INCLUDE_DUE"] == "1"
    results = CaptionGeneration::PlaceholderRefresh.call(dry_run: dry_run,
                                                         include_due: include_due)

    if results.empty?
      puts "No unpublished post is carrying the placeholder caption."
      next
    end

    puts "#{results.size} unpublished post(s) still carry the placeholder caption:"
    results.each do |r|
      line = +"  ##{r.post_id} #{r.outcome}"
      line << " (#{r.error})" if r.error
      line << " -> #{r.caption.to_s[0, 70]}" if r.caption
      puts line
    end

    if dry_run
      puts ""
      puts "DRY RUN -- nothing written. This edits what the public account will " \
           "say, so it is opt-in: re-run with APPLY=1 to replace them."
    else
      puts ""
      puts "refreshed #{results.count { |r| r.outcome == :refreshed }}, " \
           "failed #{results.count { |r| r.outcome == :failed }}"
    end
  end
end
