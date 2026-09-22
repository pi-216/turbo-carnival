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

  desc 'Top up the scheduled-post queue to meet cadence targets (SYNC_BUDGET_SECONDS bounds the work)'
  task :sync_cadence, [:persona_name] => :environment do |_t, args|
    persona = Persona.find_by(name: args[:persona_name]) || Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    unless goal
      puts 'No active goal — creating one.'
      goal = Growth::Goal.create!(persona: persona)
    end

    # A caller that is itself time-boxed (the growth tick runs this in the
    # foreground of a timed tool call) passes its budget here, so the producer
    # stops BEFORE starting a render it cannot finish instead of being killed
    # mid-render. Omitted/0 = unbounded, exactly the previous behaviour.
    budget = ENV['SYNC_BUDGET_SECONDS'].presence&.to_i
    result = Growth::CadenceEngine.new(goal: goal, budget_seconds: budget).sync
    puts "Cadence sync: existing=#{result[:existing]} target=#{result[:target]} created=#{result[:created]} shortfall=#{result[:shortfall]}"
    if result[:budget_exhausted]
      puts "Budget: stopped after #{result[:elapsed_seconds]}s (budget #{budget}s) with shortfall " \
           "#{result[:shortfall]} still open — the NEXT tick tops up the remainder (sync counts existing posts)."
    end
    salvage = result[:salvage] || {}
    if salvage[:examined].to_i.positive? || salvage[:recovered].to_i.positive?
      puts "Salvage: examined=#{salvage[:examined]} recovered=#{salvage[:recovered]} rejected=#{salvage[:rejected]} skipped=#{salvage[:skipped]} posts=#{(salvage[:post_ids] || []).inspect}"
    end
  end

  desc 'Pre-publish age gate: hold queued posts whose render reads juvenile (dry run; APPLY=1 to hold, LIMIT=N)'
  task :age_gate, [:persona_name] => :environment do |_t, args|
    persona = args[:persona_name] ? Persona.find_by(name: args[:persona_name]) : Persona.first
    apply = ENV['APPLY'] == '1'
    limit = (ENV['LIMIT'].presence || Growth::PersonaAgeGate::DEFAULT_LIMIT).to_i

    results = Growth::PersonaAgeGate.call(persona: persona, dry_run: !apply, limit: limit)

    if results.empty?
      puts 'Age gate: nothing to read (no unpublished future post without a recorded read)'
    end

    results.each do |r|
      mark = { held: 'HELD', would_hold: 'WOULD HOLD', cleared: 'adult', would_clear: 'adult',
               skipped: 'unreadable', undecided: 'undecided' }.fetch(r.outcome, r.outcome.to_s)
      puts "Age gate: post #{r.post_id} (photo #{r.photo_id}) -> #{r.verdict} [#{mark}] " \
           "model=#{r.model} read=#{r.read.to_s.inspect}"
      puts "  error: #{r.error}" if r.error
    end

    held = results.count { |r| r.outcome == :held }
    would = results.count { |r| r.outcome == :would_hold }

    # Forced holds: a post an EARLIER independent read flagged that the gate's own
    # structured probe clears. The two reads disagree, so the risk is unresolved
    # and the conservative action (hold, re-render) is taken explicitly and
    # audibly -- never by hand-editing the row. HOLD_POSTS=345 HOLD_REASON='...'
    if ENV['HOLD_POSTS'].present?
      reason = ENV['HOLD_REASON'].presence || 'forced hold (operator decision)'
      ENV['HOLD_POSTS'].split(',').map(&:strip).reject(&:empty?).each do |id|
        post = Scheduling::Post.find_by(id: id.to_i)
        if post.nil?
          puts "Age gate: HOLD_POSTS #{id} -- no such post"
          next
        end
        unless apply
          puts "Age gate: post #{post.id} WOULD BE HELD (forced) — #{reason}"
          would += 1
          next
        end
        begin
          r = Growth::PersonaAgeGate.hold!(post: post, read: "forced: #{reason}", reason: reason)
          puts "Age gate: post #{r.post_id} (photo #{r.photo_id}) -> #{r.verdict} [HELD FORCED] #{reason}"
          held += 1
        rescue StandardError => e
          puts "Age gate: post #{post.id} could not be held: #{e.class} - #{e.message}"
        end
      end
    end

    puts "Age gate: #{results.size} read, #{held} held, #{would} would hold, " \
         "#{results.count { |r| r.outcome == :skipped }} unreadable (dry_run=#{!apply})"
    # Deliberately exit 0: a HOLD is the gate working, not a failure. The
    # publisher treats a non-zero here as a WARN and publishes anyway.
  end

  desc 'Recover abandoned renders into the queue (GPU-free; bounded by the cadence shortfall)'
  task :salvage_abandoned, [:persona_name] => :environment do |_t, args|
    persona = args[:persona_name] ? Persona.find_by(name: args[:persona_name]) : Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    if goal.nil?
      puts 'Salvage: no active goal — nothing to recover into.'
      next
    end

    outcome = Growth::CadenceEngine.new(goal: goal).recover_abandoned
    if outcome[:result].nil?
      puts "Salvage: skipped — queue at target (existing=#{outcome[:existing]} " \
           "target=#{outcome[:target]}); nothing to recover into"
      next
    end

    result = outcome[:result]
    puts "Salvage: examined=#{result.examined} recovered=#{result.recovered} " \
         "rejected=#{result.rejected} skipped=#{result.skipped} " \
         "posts=#{result.post_ids.inspect} (shortfall=#{outcome[:shortfall]})"
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

  # The pre-registered GO/PIVOT/KILL criterion lived only as PROSE on the ops
  # board, and its cohort-validity rule (whether the engagement leg is a
  # measurement at all) took a full ops pass to derive from the data. Run this
  # instead of re-deriving it: it reads the SAME window the weekly review judges
  # on, via Growth::WeeklyReview#gate_inputs. Read-only -- no writes, no persona
  # mutation, exit 0 on every verdict (only a missing goal is a failure).
  desc 'Pre-registered GO/PIVOT/KILL gate read for the growth thesis (read-only)'
  task :gate, [:persona_name] => :environment do |_t, args|
    persona = args[:persona_name] ? Persona.find_by(name: args[:persona_name]) : Persona.first
    goal = Growth::Goal.active.for_persona(persona).first
    if goal.nil?
      puts "gate: no active goal for #{persona&.name || 'any persona'}"
      exit 1
    end

    read = Growth::GateRead.new(goal: goal).call
    f = read[:followers]
    e = read[:engagement]

    puts "gate=#{read[:verdict]} " \
         "followers=#{f[:value]}/#{f[:ceiling]}#{f[:pass] ? ' PASS' : ' FAIL'} " \
         "max_pillar_eng=#{e[:max]}%#{e[:pass] ? ' PASS' : ' FAIL'} " \
         "(floor #{e[:floor]}%, top=#{e[:max_pillar]}) " \
         "window=#{e[:window_days]}d posts=#{e[:window_posts]} " \
         "cohort=#{e[:cohort]}/#{e[:min_cohort]}#{e[:cohort_valid] ? '' : ' INVALID'}"
    puts "reason: #{read[:reason]}"
    puts 'pillars in window:'
    read[:pillars].each do |p|
      puts "  #{p[:name].ljust(28)} posts=#{p[:posts]} avg_eng=#{p[:engagement]}% reach=#{p[:reach]} likes=#{p[:likes]}"
    end
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