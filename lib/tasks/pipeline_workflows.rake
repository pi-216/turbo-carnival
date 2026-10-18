# frozen_string_literal: true

# Load versioned ComfyUI workflows from `comfy_workflows/<slug>/` into the database.
#
# WHY THIS EXISTS
# ---------------
# A render workflow used to exist ONLY as a Postgres text column
# (`pipeline_steps.comfy_workflow_json`). Nothing in git held it, so nothing
# could diff it -- and an agent silently rewrote a copy's identity prompt (node
# 88) into "fully clothed, modest", wired that copy into production, and no
# review could have caught it (measured 2026-10-18, docs/strategy-v2.md §12).
#
# So the FILE is the source of truth and the database is a LOAD TARGET: the
# workflow becomes reviewable, revertable and attributable in git, and a change
# to it arrives as a diff on a pull request instead of a silent UPDATE.
#
# USAGE
#   rake "pipeline:register[comfy_workflows/turbo_one_step_v2,turbo-one-step-v2]"
#
# Idempotent: re-running replaces each step's workflow FROM THE FILE (the file
# wins -- that is the whole point), and never touches a different pipeline.
namespace :pipeline do
  desc 'Register/update a pipeline from versioned workflow files in a directory'
  task :register, %i[dir pipeline_name] => :environment do |_task, args|
    dir  = args[:dir].to_s
    name = args[:pipeline_name].to_s

    raise 'usage: rake pipeline:register[<dir>,<pipeline-name>]' if dir.empty? || name.empty?
    raise "not a directory: #{dir} (run from the repo root)" unless File.directory?(dir)

    files = Dir.glob(File.join(dir, 'step*.json')).sort_by do |f|
      File.basename(f)[/\Astep(\d+)/, 1].to_i
    end
    raise "no step*.json files in #{dir}" if files.empty?

    pipeline = Pipeline.find_or_initialize_by(name: name)
    created = pipeline.new_record?
    pipeline.description ||= "Workflows loaded from #{dir} (file is the source of truth)"
    pipeline.save!
    puts "pipeline #{pipeline.id} #{pipeline.name}#{created ? ' (created)' : ' (existing)'}"

    files.each do |file|
      order = File.basename(file)[/\Astep(\d+)/, 1].to_i
      raw   = File.read(file)

      # The file MUST be the ComfyUI API graph ({node => {class_type, inputs}}).
      # A UI export would sit happily in the text column and then be rejected by
      # ComfyUI at submit time -- mid-render, after the model load. Catch it here.
      graph = JSON.parse(raw)
      unless graph.is_a?(Hash) && !graph.empty? &&
             graph.values.all? { |n| n.is_a?(Hash) && n.key?('class_type') }
        raise "#{file}: not a ComfyUI API-format graph (need {node => {class_type, inputs}})"
      end

      tokens = raw.scan(/\{\{([A-Za-z0-9_]+)\}\}/).flatten.uniq.sort

      step = pipeline.pipeline_steps.find_or_initialize_by(order: order)
      step.name = File.basename(file, '.json')
                      .sub(/\Astep\d+_/, '')
                      .tr('_', ' ')
                      .split.map(&:capitalize).join(' ')
      step.comfy_workflow_json = raw
      # The workflow is parameterised at RUNTIME from the run's variables (that is
      # where {{checkpoint}} and {{prompt}} come from), so the prompt is not a
      # separate column-driven input on this rail.
      step.needs_run_prompt = false
      step.needs_run_variables = true
      step.needs_parent_image_path = false
      step.save!

      puts "  step #{step.id} order=#{order} #{step.name} " \
           "nodes=#{graph.size} tokens=#{tokens.inspect}"
    end

    puts "done. pipeline_steps=#{pipeline.pipeline_steps.count} total_pipelines=#{Pipeline.count}"
  end
end
