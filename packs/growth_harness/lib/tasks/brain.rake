# frozen_string_literal: true

namespace :brain do
  # Resolve the active goal the decision row attaches to (mirrors growth.rake).
  active_goal = lambda do |persona_name|
    persona = persona_name ? Persona.find_by(name: persona_name) : Persona.first
    Growth::Goal.active.for_persona(persona).first
  end

  desc 'Report the brain gate (claim=<idle|ours|other> brain=<up|down> ready=<yes|no>)'
  task :status, [ :persona_name ] => :environment do |_t, args|
    gate = Growth::BrainGate.status
    puts "brain claim=#{gate.claim_state} brain=#{gate.brain_up ? 'up' : 'down'} " \
         "ready=#{gate.ready? ? 'yes' : 'no'} | #{gate.raw}"
  end

  # Cron check-in: a SILENTLY-DEAD brain is an alert, not a discovery. The seat is
  # transient — up only for a batch — so "down with no claim of ours" is the NORMAL
  # idle state and must NOT row. Alert only on an anomaly:
  #   * ours && !brain_up  -> we hold the 4090 and the server died mid-batch
  #   * brain_up && !ours  -> a server is answering with no claim covering it (leak)
  # Either surfaces as a `brain_unclaimed` decision row (the ledger the render phase
  # already uses for comfyui_unclaimed), so reviewers see it without being asked.
  desc 'Cron check-in: record brain_unclaimed on a dead-while-claimed or unmetered brain'
  task :checkin, [ :persona_name ] => :environment do |_t, args|
    gate = Growth::BrainGate.status
    goal = active_goal.call(args[:persona_name])
    anomaly = (gate.ours && !gate.brain_up) || (gate.brain_up && !gate.ours)
    state = "claim=#{gate.claim_state} brain=#{gate.brain_up ? 'up' : 'down'} ours=#{gate.ours ? 'yes' : 'no'}"

    if anomaly
      Growth::BrainGate.record_unclaimed!(goal: goal, gate: gate) if goal
      note = goal ? '' : ' (no active goal: row NOT written)'
      puts "brain:checkin ALERT — #{state}#{note} | #{gate.raw}"
    else
      puts "brain:checkin OK — #{state} (normal) | #{gate.raw}"
    end
  end

  # The NIGHTLY planner window (PRD 0001, ticket #64; founder ruling 2026-10-19: the
  # planner runs once a night). The GPU claim + the seat's lifecycle belong to
  # bin/brain_plan_nightly.sh, which calls this task; here we only plan and persist,
  # so this is runnable with no GPU and no claim.
  desc 'Nightly planner: propose content clusters on the LOCAL BRAIN (fail-soft if the seat is down)'
  task :plan, [ :persona_name ] => :environment do |_t, args|
    force = ENV['FORCE'] == '1'
    result = Growth::NightlyPlanner.new(persona_name: args[:persona_name], force: force).call

    if result.seat_up
      puts "brain:plan DONE — personas=#{result.personas} pillars=#{result.pillars} " \
           "suggestions=#{result.suggestions} skipped=#{result.skipped_personas}"
      if result.skipped_personas.positive?
        puts "brain:plan: #{result.skipped_personas} persona(s) already planned today — " \
             "idempotent no-op. Set FORCE=1 to re-plan."
      end
    else
      puts "brain:plan SKIPPED — seat not answering: no proposals written. " \
           "Normal outcome; the hourly loop never depends on this window."
    end
  end
end
