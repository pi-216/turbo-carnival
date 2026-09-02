# frozen_string_literal: true

namespace :growth do
  desc 'Run the full growth harness loop (snapshot, cadence, review) for a persona'
  task :run_all, [:persona_name] => :environment do |_t, args|
    harness = Growth::Harness.new(persona_name: args[:persona_name])
    result = harness.run_all

    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    puts '  Growth Harness Run'
    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

    if result[:error]
      puts "❌ #{result[:error]}"
      exit 1
    end

    goal = result[:goal]
    puts "Persona:    #{goal.persona.name}"
    puts "Followers:  #{goal.latest_followers} / #{goal.target_followers} (target)"
    puts "Deadline:   #{goal.deadline} (#{goal.days_remaining} days left)"
    puts "Cadence:    #{goal.posts_per_day}/day (max #{goal.max_posts_per_day})"

    snapshot = result[:snapshot]
    if snapshot
      puts "Snapshot:   ✅ #{snapshot.followers} followers @ #{snapshot.taken_at.strftime('%Y-%m-%d %H:%M')}"
    else
      puts 'Snapshot:   ⚠️  not captured (API error — see decision log)'
    end

    cadence = result[:cadence]
    puts "Queue:      #{cadence[:existing]} existing, target #{cadence[:target]}, created #{cadence[:created]}"

    review = result[:review]
    puts "Review:     #{review.inspect}"
    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  end

  desc 'Top up the scheduled-post queue to meet cadence targets'
  task :sync_cadence, [:persona_name] => :environment do |_t, args|
    persona = Persona.find_by(name: args[:persona_name]) || Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — creating one.'
      goal = Growth::Goal.create!(persona: persona)
    end

    result = Growth::CadenceEngine.new(goal: goal).sync
    puts "Cadence sync: existing=#{result[:existing]} target=#{result[:target]} created=#{result[:created]} shortfall=#{result[:shortfall]}"
  end

  desc 'Capture a follower-count snapshot for the active goal'
  task :snapshot_followers, [:persona_name] => :environment do |_t, args|
    persona = args[:persona_name] ? Persona.find_by(name: args[:persona_name]) : Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — creating one.'
      goal = Growth::Goal.create!(persona: persona)
    end

    snapshot = Growth::MetricsCollector.new(goal: goal).collect
    if snapshot
      puts "Snapshot recorded: #{snapshot.followers} followers"
    else
      puts 'Snapshot failed (see decision log / Rails log for reason)'
    end
  end

  desc 'Run the strategy review brain (respects review interval unless FORCE=1)'
  task :review_strategy, [:persona_name] => :environment do |_t, args|
    persona = Persona.find_by(name: args[:persona_name]) || Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — nothing to review.'
      exit 0
    end

    result = Growth::StrategyBrain.new(goal: goal).review(force: ENV['FORCE'] == '1')
    puts "Review result: #{result.inspect}"
  end

  desc 'Print growth harness status for all goals'
  task status: :environment do
    Growth::Goal.includes(:persona, :snapshots).find_each do |goal|
      puts "#{goal.persona.name.ljust(14)} | #{goal.latest_followers}/#{goal.target_followers} | " \
           "#{goal.days_elapsed}d elapsed / #{goal.days_remaining}d left | " \
           "cadence #{goal.posts_per_day}/day | ratio #{goal.traj_ratio&.round(2) || 'n/a'} | " \
           "#{goal.status} | snapshots=#{goal.snapshots.count}"
    end
  end

  desc 'Generate N fresh turbo-one-step renders and schedule them as posts (default 1)'
  task :generate_content, %i[persona_name count] => :environment do |_t, args|
    persona = Persona.find_by(name: args[:persona_name]) || Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — creating one.'
      goal = Growth::Goal.create!(persona: persona)
    end
    count = [args[:count].to_i, 1].max
    puts "Generating #{count} fresh turbo-one-step renders for #{persona.name}..."
    ok = 0
    count.times do |i|
      result = Growth::ContentGenerator.new(goal: goal).generate_one(offset_days: i + 1)
      if result[:success]
        ok += 1
        puts "  ✅ post #{result[:post_id]} scheduled (photo #{result[:photo_id]})"
      else
        puts "  ❌ #{result[:error]}"
        break
      end
    end
    puts "Done: #{ok}/#{count} fresh posts scheduled"
  end

  desc 'Report render need + scheduler claim state (shortfall=X need=yes|no claim=<idle|ours|other> comfy=up|down)'
  task :render_need, [:persona_name] => :environment do |_t, args|
    persona = args[:persona_name] ? Persona.find_by(name: args[:persona_name]) : Persona.first
    goal = Growth::Goal.active.for_persona(persona).first

    target = existing = shortfall = 0
    if goal
      target = (goal.effective_posts_per_day * Growth::CadenceEngine::LOOKAHEAD_DAYS).ceil
      existing = Scheduling::Post
                 .where(persona: goal.persona)
                 .where(status: %w[draft scheduled])
                 .where('scheduled_at > ? OR optimal_time_calculated > ?', Time.current, Time.current)
                 .count
      shortfall = [target - existing, 0].max
    end

    gate = Growth::SchedulerGate.status
    puts "shortfall=#{shortfall} target=#{target} existing=#{existing} " \
         "need=#{shortfall.positive? ? 'yes' : 'no'} claim=#{gate.claim_state} comfy=#{gate.comfyui_up ? 'up' : 'down'}"
  end

  desc 'Weekly step-back review: trajectory + per-pillar engagement + persona evolution (DRY=1 audits without changing)'
  task :weekly_review, [:persona_name] => :environment do |_t, args|
    persona = Persona.find_by(name: args[:persona_name]) || Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — nothing to review.'
      exit 0
    end

    apply = ENV['DRY'] != '1'
    result = Growth::WeeklyReview.new(goal: goal).review(apply: apply, force: true)

    review = result[:review]
    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    puts '  Weekly Review (persona experiment)'
    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    if review.is_a?(Hash) # need_data
      puts "verdict: #{review[:verdict]}"
      puts "  snapshots=#{review[:snapshots]} posts=#{review[:posts]} (need >=2 snapshots and >=5 posts)"
      exit 0
    end

    puts "verdict:        #{review.verdict}"
    puts "followers:      #{review.followers} (delta #{review.followers_delta})"
    puts "trajectory:     required #{review.required_daily}/day vs measured #{review.measured_daily}/day (ratio #{review.trajectory_ratio})"
    puts "persona:        #{review.persona_direction}"
    puts ''
    puts 'pillar engagement:'
    (review.pillar_engagement || {}).each do |name, p|
      puts "  #{name.ljust(28)} posts=#{p['posts']} avg_eng=#{p['engagement']}% reach=#{p['reach']} likes=#{p['likes']}"
    end
    puts ''
    puts 'recommendations:'
    (review.recommendations || []).each { |r| puts "  - #{r}" }
    puts ''
    if (review.applied_changes || []).any?
      puts 'changes applied (bounded, reversible):'
      review.applied_changes.each { |c| next unless c.is_a?(Hash); puts "  [#{c['kind']}] #{c['reason']}: #{c['from'].inspect} -> #{c['to'].inspect}" }
      puts ''
      puts "DRY RUN: audit only, no changes made" unless apply
    else
      puts 'no persona changes applied this cycle'
    end
    puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  end
end