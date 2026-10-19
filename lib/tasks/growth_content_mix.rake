# frozen_string_literal: true

# Set the persona's CONTENT MIX and hashtag volume from measured evidence.
#
# WHY THIS IS A TASK AND NOT A ONE-OFF: the mix lives in the DB, and the
# decisions behind it are the operating agent's, so they have to be reviewable
# and reversible — this prints a dry-run plan by default, backs up the before
# state, and writes only with APPLY=1. Every number below cites the measurement
# it came from; rerun it and the plan is reproduced exactly.
#
# SOURCE OF THE EVIDENCE: the weekly persona review of 2026-09-21 (the 7 days
# ending that date), which read per-post insights from the live account:
#
#   pillar                       posts  avg engagement
#   Fashion & Style                35        1.95%
#   Food & Cooking                  9        2.22%
#   Lifestyle & Daily Living       29        1.12%
#   Wellness & Self-Care           16        0.31%
#   Beauty & Self-Care             14        0.00%
#   Travel & Adventure             14        0.00%
#   Fitness & Wellness             12        0.00%
#   Community & Social Proof       10        0.00%
#
# Four pillars are at a dead zero after 10-14 posts each, which is not noise —
# the account's whole reach is 1-4 per post. They are RETIRED from rotation
# (active=false; photos and history are untouched, and this is reversible by
# setting active back). Weight is concentrated on the pillars that show signal.
#
# Weight is not decoration: Growth::CadenceEngine now draws pillars in
# weighted-random order, so `weight` is the share of renders a pillar gets.
namespace :growth do
  desc "Report (APPLY=1 to write) the content mix: retire dead pillars, weight the signal, reset tag volume"
  task content_mix: :environment do
    dry_run = ENV["APPLY"] != "1"
    persona = Growth::Goal.active.first&.persona
    abort "no active growth goal/persona" unless persona

    # weight/priority per pillar that SURVIVES, chosen from the table above:
    # the two with the most reach and evidence lead, food keeps a real share
    # (best rate, thinnest sample), wellness a residual share. Sums to 100.
    NEW_WEIGHTS = {
      "Fashion & Style"           => { weight: 35, priority: 5 },
      "Lifestyle & Daily Living"  => { weight: 25, priority: 4 },
      "Food & Cooking"            => { weight: 25, priority: 4 },
      "Wellness & Self-Care"      => { weight: 15, priority: 3 }
    }.freeze

    pillars = persona.content_pillars.order(:id).to_a

    # Anything not in NEW_WEIGHTS is retired from rotation: the four
    # dead-engagement pillars and the expired seasonal campaigns (2024/2025
    # windows). Nothing is deleted — active=false only.
    kept = pillars.select { |p| NEW_WEIGHTS.key?(p.name) }
    retired = pillars - kept

    puts "persona ##{persona.id} #{persona.name}"
    puts "RETIRE (#{retired.size}):"
    retired.each do |p|
      puts "  ##{p.id} #{p.name} (weight #{p.weight}, priority #{p.priority}, end #{p.end_date.inspect})"
    end
    puts "KEEP + REWEIGHT (#{kept.size}):"
    kept.each do |p|
      target = NEW_WEIGHTS[p.name]
      next unless target

      puts "  ##{p.id} #{p.name}: weight #{p.weight} -> #{target[:weight]}, priority #{p.priority} -> #{target[:priority]}"
    end

    strategy = persona.hashtag_strategy
    target_tags = Growth::PersonaEvolution::TAG_BASELINE
    puts "HASHTAGS: max_tags #{strategy&.max_tags} -> #{target_tags} (baseline; the 10 -> 30 ramp bought no engagement)"

    if dry_run
      puts "\nDRY RUN — nothing written. Re-run with APPLY=1 to apply."
      next
    end

    backup_dir = Rails.root.join("ops", "backups")
    FileUtils.mkdir_p(backup_dir)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup = backup_dir.join("content-mix-#{stamp}.json")
    backup.write(JSON.pretty_generate(
      persona: { id: persona.id, name: persona.name },
      taken_at: stamp,
      pillars: pillars.map { |p| { id: p.id, name: p.name, weight: p.weight, priority: p.priority, active: p.active } },
      hashtag_strategy: strategy&.to_hash
    ))
    puts "backup written: #{backup}"

    ContentPillar.transaction do
      # Retire first: the active-weight total must not exceed 100 at any point.
      retired.each { |p| p.update!(active: false) }

      kept.each do |p|
        target = NEW_WEIGHTS[p.name]
        next unless target

        p.update!(weight: target[:weight], priority: target[:priority], active: true)
      end

      if target_tags && strategy&.max_tags.to_i != target_tags
        persona.hashtag_strategy = Personas::HashtagStrategy.new(
          strategy.to_hash.merge(max_tags: target_tags)
        )
        persona.save!
      end
    end

    persona.reload
    puts "\nAPPLIED. Active pillars now:"
    persona.content_pillars.current.order(weight: :desc).each do |p|
      puts "  #{p.name} weight=#{p.weight} priority=#{p.priority}"
    end
    puts "max_tags=#{persona.hashtag_strategy&.max_tags}"
  end
end
