class SelectNextJob < GLCommand::Callable
  returns :parent_candidate, :next_step, :mode, :pipeline_run

  # Statuses that mean "this run still wants work". `failed` is TERMINAL and must
  # never be reworked. Selecting `where.not(status: 'completed')` swept failed runs
  # into the workable set, and on 2026-09-19 the submitter was still dispatching the
  # deprecated sarah-carnival-v1 (pony/SDXL) and turbo-one-step runs from May/August
  # (374 dead runs). Those pony renders landed next to the growth harness's flux
  # render, both model families stayed cached in VRAM, and the flux job OOM'd at
  # SamplerCustomAdvanced (out of memory) — the render_need queue then starved.
  WORKABLE_STATUSES = %w[pending running].freeze

  # A run created by a SYNCHRONOUS producer (Growth::ContentGenerator submits its
  # own ComfyuiJob and polls it to completion) must never be dispatched a second
  # time by this async selector: while its render is in flight the run record still
  # looks unworked, so this command queued a DUPLICATE render for the same run.
  # Producers tag their runs with variables['sync_producer'].
  SYNC_PRODUCER_KEY = 'sync_producer'.freeze

  def call
    # Select a run that needs work (round-robin)
    selected_run = select_run_needing_work
    
    unless selected_run
      context.mode = :no_work
      context.pipeline_run = nil
      context.parent_candidate = nil
      context.next_step = nil
      Rails.logger.info("SelectNextJob: No active runs need work")
      return
    end

    # Work on the selected run
    work_on_run(selected_run)
  end

  private

  def select_run_needing_work
    active_runs = PipelineRun.where(status: WORKABLE_STATUSES)
                             .where("(pipeline_runs.variables ->> :key) IS NULL",
                                    key: SYNC_PRODUCER_KEY)
                             .order(:id).to_a
    
    return nil if active_runs.empty?
    
    # Get last worked run ID from cache/session
    last_worked_id = Rails.cache.read('last_worked_run_id') || 0
    
    # Find next run after last_worked that needs work
    start_index = active_runs.index { |r| r.id > last_worked_id } || 0
    
    # Check from start_index to end
    (start_index...active_runs.size).each do |i|
      run = active_runs[i]
      if run_needs_work?(run)
        Rails.cache.write('last_worked_run_id', run.id)
        return run
      end
    end
    
    # Wrap around: check from beginning to start_index
    (0...start_index).each do |i|
      run = active_runs[i]
      if run_needs_work?(run)
        Rails.cache.write('last_worked_run_id', run.id)
        return run
      end
    end
    
    nil
  end

  def run_needs_work?(run)
    pipeline = run.pipeline
    
    # Check if base step needs more candidates
    first_step = pipeline.pipeline_steps.first
    base_count = ImageCandidate.where(
      pipeline_step: first_step,
      pipeline_run: run,
      status: 'active'
    ).count
    
    max_children = first_step.max_children || JobOrchestrationConfig.max_children_per_node
    return true if base_count < max_children
    
    # Check if any parent needs more children
    pipeline.pipeline_steps.order(:order).each do |step|
      next if step == first_step
      
      # Find parents from previous step
      prev_step = pipeline.pipeline_steps.where("\"order\" < ?", step.order).reorder("\"order\" DESC").first
      next unless prev_step
      
      # Get all active parents at previous step
      parents = ImageCandidate.where(
        pipeline_step: prev_step,
        pipeline_run: run,
        status: 'active'
      )
      
      # Check if any parent needs more children
      step_max_children = step.max_children || JobOrchestrationConfig.max_children_per_node
      parents.each do |parent|
        child_count = parent.children.where(
          pipeline_step: step,
          status: 'active'
        ).count
        return true if child_count < step_max_children
      end
    end
    
    false
  end

  def work_on_run(run)
    context.pipeline_run = run
    Rails.logger.info("SelectNextJob: Working on run #{run.id} (#{run.name})")
    
    # FIRST: Ensure step 1 has minimum candidates
    first_step_check = ensure_minimum_base_images(run)
    return if first_step_check

    eligible_parents = find_eligible_parents(run)

    if eligible_parents.any?
      handle_child_generation(run, eligible_parents)
    else
      handle_no_eligible_parents(run)
    end
  end

  def ensure_minimum_base_images(run)
    pipeline = run.pipeline
    first_step = pipeline.pipeline_steps.first
    
    return false unless first_step
    
    min_candidates_per_step = first_step.max_children || JobOrchestrationConfig.max_children_per_node
    
    step1_count = ImageCandidate.where(
      pipeline_step: first_step,
      pipeline_run: run,
      status: "active"
    ).count
    
    # Step 1 always generates - no approval gate needed
    if step1_count < min_candidates_per_step
      in_flight_count = ComfyuiJob.where(
        pipeline_step: first_step,
        pipeline_run: run,
        status: %w[pending submitted running]
      ).count
      
      # Only submit if not already in flight
      if in_flight_count < min_candidates_per_step
        context.parent_candidate = nil
        context.next_step = first_step
        context.mode = :base_generation
        Rails.logger.info("SelectNextJob: Run #{run.id} - Filling step 1 to #{min_candidates_per_step} candidates (#{step1_count} active, #{in_flight_count} in flight)")
        return true
      end
    end
    
    false
  end

  def find_eligible_parents(run)
    max_failures = ENV.fetch("MAX_PARENT_FAILURES", 3).to_i
    pipeline = run.pipeline

    # Get ID of final step
    final_step_id = pipeline.pipeline_steps.max_by(&:order)&.id

    # We'll need to check max_children per step in the filter below
    candidates = ImageCandidate
      .includes(pipeline_step: :pipeline)
      .where(status: "active")
      .where(pipeline_run: run)
      .where("failure_count < ?", max_failures)
      .where.not(pipeline_step_id: final_step_id)
    
    # Filter by approval: current step must be approved to become parents
    # Also check if parent has room for more children based on step's max_children
    candidates.select do |candidate|
      step = candidate.pipeline_step
      max_children = step.max_children || JobOrchestrationConfig.max_children_per_node
      candidate.child_count < max_children &&
        step_approved_for_run?(step, run) &&
        in_top_k?(candidate, run)
    end
  end
  
  def step_approved_for_run?(step, run)
    run.step_approved?(step)
  end
  
  def in_top_k?(candidate, run)
    prs = run.pipeline_run_steps.find_by(pipeline_step: candidate.pipeline_step)
    return false unless prs&.approved?
    
    k = prs.top_k_count
    top_k_ids = ImageCandidate
      .where(pipeline_step: candidate.pipeline_step, pipeline_run: run, status: 'active')
      .order(elo_score: :desc)
      .limit(k)
      .pluck(:id)
    
    top_k_ids.include?(candidate.id)
  end

  def handle_child_generation(run, eligible_parents)
    parents_with_order = eligible_parents.to_a
    return if parents_with_order.empty?

    # Per-parent breadth-first: each parent gets N children before advancing
    pipeline = run.pipeline
    
    # Find the earliest step that has parents needing more children
    pipeline.pipeline_steps.order(:order).each do |step|
      # Skip the first step (handled in ensure_minimum_base_images)
      next if step == pipeline.pipeline_steps.first
      
      # Find parents from the previous step
      prev_step = pipeline.pipeline_steps.where("\"order\" < ?", step.order).reorder("\"order\" DESC").first
      next unless prev_step
      
      # Get all active parents at previous step for this run
      parents_at_prev_step = ImageCandidate.where(
        pipeline_step: prev_step,
        pipeline_run: run,
        status: 'active'
      )
      
      # Filter to only approved top-K parents (prev_step must be approved)
      prs = run.pipeline_run_steps.find_by(pipeline_step: prev_step)
      next unless prs&.approved? # Skip if previous step not approved yet
      
      parents_at_prev_step = parents_at_prev_step.select do |parent|
        in_top_k?(parent, run)
      end
      
      # Find parents that need more children at this step
      step_max_children = step.max_children || JobOrchestrationConfig.max_children_per_node
      parents_needing_children = parents_at_prev_step.select do |parent|
        child_count = parent.children.where(
          pipeline_step: step,
          status: 'active'
        ).count
        child_count < step_max_children
      end
      
      if parents_needing_children.any?
        # Select a parent that needs children (weighted by ELO)
        selected_parent = weighted_raffle(parents_needing_children)
        current_children = selected_parent.children.where(pipeline_step: step, status: 'active').count
        
        context.parent_candidate = selected_parent
        context.next_step = step
        context.mode = :child_generation
        Rails.logger.info("SelectNextJob: Run #{run.id} - Parent #{selected_parent.id} needs child at step #{step.order} (#{current_children}/#{step_max_children})")
        return
      end
    end

    # All parents have N children - check if waiting for approval
    # Check if there are any unapproved steps with candidates ready
    pipeline.pipeline_steps.order(:order).each do |step|
      prs = run.pipeline_run_steps.find_by(pipeline_step: step)
      candidate_count = ImageCandidate.where(
        pipeline_step: step,
        pipeline_run: run,
        status: 'active'
      ).count
      
      if !prs&.approved? && candidate_count > 0
        Rails.logger.info("SelectNextJob: Run #{run.id} - Waiting for Step #{step.order} (#{step.name}) approval")
        context.parent_candidate = nil
        context.next_step = nil
        context.mode = :waiting_for_approval
        return
      end
    end
    
    Rails.logger.info("SelectNextJob: Run #{run.id} - All parents have #{max_children} children")
    context.parent_candidate = nil
    context.next_step = nil
    context.mode = :no_work
  end

  def handle_no_eligible_parents(run)
    # With approval gates, we should not do deficit-based generation
    # Instead, wait for user approval at each step
    # Check for deficit mode is removed - gates control progression
    
    context.parent_candidate = nil
    context.next_step = nil
    context.mode = :no_work
  end

  def weighted_raffle(candidates)
    candidates_array = candidates.to_a
    return candidates_array.first if candidates_array.size == 1

    total_weight = candidates_array.sum(&:elo_score)

    # Handle edge case of zero total weight
    if total_weight.zero?
      return candidates_array.sample
    end

    random_value = rand(0...total_weight)

    cumulative = 0
    candidates_array.each do |candidate|
      cumulative += candidate.elo_score
      return candidate if random_value < cumulative
    end

    candidates_array.last
  end
end
