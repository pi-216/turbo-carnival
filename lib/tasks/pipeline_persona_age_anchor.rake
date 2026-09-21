# frozen_string_literal: true

# Give the persona's stored render prompt an explicit adult age anchor. See
# PersonaAgeAnchor for why this exists and what it deliberately does not change.
#
# The render path is NOT guarded by this (unlike PipelinePromptSafety, which runs
# on every payload): this task is what makes the stored workflows SAY the age, so
# the model has an anchor and a human auditing the persona can see it.
#
# Dry-run by default; APPLY=1 to write. Every write is preceded by a byte-exact
# backup of the original column value under ops/backups/, and the rewrite is a
# literal replacement of the JSON-escaped original text -- the rest of the
# workflow is never re-serialized, so nothing else can drift.
namespace :pipeline do
  desc "Report (APPLY=1 to write) the persona's missing adult age anchor in stored workflows"
  task persona_age_anchor: :environment do
    dry_run = ENV['APPLY'] != '1'
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    backup_dir = Rails.root.join('ops', 'backups')
    # The two pipelines the growth harness renders with (Growth::ContentGenerator):
    # the production path and its fallback. Any other pipeline is left alone --
    # it is not producing the account's images.
    target_names = [ 'turbo-one-step-clean', 'turbo-one-step' ]
    dirty = []
    unparseable = []

    PipelineStep.includes(:pipeline).order(:id).each do |step|
      next unless target_names.include?(step.pipeline&.name)

      raw = step.comfy_workflow_json.to_s
      begin
        wf = JSON.parse(raw)
      rescue JSON::ParserError => e
        unparseable << [ step, e.message ]
        next
      end

      _anchored, changes = PersonaAgeAnchor.anchor_workflow(wf)
      dirty << [ step, raw, changes ] if changes.any?
    end

    if unparseable.any?
      puts "#{unparseable.size} step(s) could not be parsed (skipped):"
      unparseable.each { |step, msg| puts "  ##{step.id}: #{msg}" }
      puts
    end

    if dirty.empty?
      puts "Every stored workflow on the render path already states an adult age " \
           "(or carries no persona identity line)."
      next
    end

    puts "#{dirty.size} pipeline step(s) carry the persona identity with no age anchor:"
    dirty.each do |step, _raw, changes|
      puts "  ##{step.id} (pipeline #{step.pipeline_id} '#{step.pipeline.name}', step '#{step.name}')"
      changes.each do |c|
        puts "    #{c}"
      end
    end
    puts

    if dry_run
      puts 'DRY RUN -- nothing written. Re-run with APPLY=1 to write the anchor.'
      next
    end

    FileUtils.mkdir_p(backup_dir)
    written = 0
    dirty.each do |step, raw, changes|
      backup = backup_dir.join("pipeline_step_#{step.id}_pre_age_anchor_#{stamp}.json")
      File.write(backup, raw)

      new_raw = raw.dup
      changes.each do |c|
        # Literal (block form: no backreference interpretation) replacement of the
        # JSON-escaped original text, so only that value changes.
        new_raw = new_raw.gsub(c.before.to_json[1..-2]) { c.after.to_json[1..-2] }
      end

      begin
        reparsed = JSON.parse(new_raw)
      rescue JSON::ParserError => e
        puts "  ##{step.id} SKIPPED -- rewrite would not parse (#{e.message}); backup at #{backup}"
        next
      end

      # The anchor must SURVIVE the render-time guard, or the write is theatre.
      _guarded, guard_changes = PipelinePromptSafety.sanitize_workflow(reparsed)
      if guard_changes.any?
        puts "  ##{step.id} SKIPPED -- the render-time prompt guard would rewrite the " \
             "anchored text (#{guard_changes.size} change(s)); backup at #{backup}"
        next
      end

      _again, remaining = PersonaAgeAnchor.anchor_workflow(reparsed)
      if remaining.any?
        puts "  ##{step.id} SKIPPED -- anchor did not take; backup at #{backup}"
        next
      end

      step.update!(comfy_workflow_json: new_raw)
      written += 1
      puts "  ##{step.id} anchored (#{changes.size} rewrite(s)); original backed up to #{backup}"
    end
    puts "anchored #{written} of #{dirty.size} step(s)"
  end
end
