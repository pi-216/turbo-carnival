# frozen_string_literal: true

# Repair stored workflow text that directs a minor or conditions against
# adulthood. See PipelinePromptSafety for why this exists.
#
# The render path is already guarded (BuildJobPayload runs every workflow through
# PipelinePromptSafety), so this task is not what protects a render -- it removes
# the hazard from the SOURCE: a stored workflow is what the admin UI shows and
# edits, what a human reads when auditing the persona, and what any other
# consumer of pipeline_steps.comfy_workflow_json inherits.
#
# Dry-run by default; APPLY=1 to write. Every write is preceded by a byte-exact
# backup of the original column value under ops/backups/, and the rewrite is a
# literal replacement of the JSON-escaped original text -- the rest of the
# workflow is never re-serialized, so nothing else can drift.
namespace :pipeline do
  desc "Report (APPLY=1 to repair) stored workflow text that directs a minor or " \
       "suppresses adult features"
  task prompt_safety: :environment do
    dry_run = ENV["APPLY"] != "1"
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup_dir = Rails.root.join("ops", "backups")
    dirty = []
    unparseable = []

    PipelineStep.order(:id).each do |step|
      raw = step.comfy_workflow_json.to_s
      begin
        wf = JSON.parse(raw)
      rescue JSON::ParserError => e
        unparseable << [ step, e.message ]
        next
      end

      _sanitized, changes = PipelinePromptSafety.sanitize_workflow(wf)
      dirty << [ step, raw, changes ] if changes.any?
    end

    if unparseable.any?
      puts "#{unparseable.size} step(s) could not be parsed (skipped):"
      unparseable.each { |step, msg| puts "  ##{step.id}: #{msg}" }
      puts
    end

    if dirty.empty?
      puts "No stored workflow carries a minor direction or an adult-suppressing negative token."
      next
    end

    puts "#{dirty.size} pipeline step(s) carry prompt-safety violations:"
    dirty.each do |step, _raw, changes|
      puts "  ##{step.id} (pipeline #{step.pipeline_id} '#{step.pipeline.name}', step '#{step.name}')"
      changes.each do |c|
        puts "    [#{c.kind}] node #{c.node_id} role=#{c.role} key=#{c.key}"
        puts "      before: #{c.before.to_s[-160..].inspect}"
        puts "      after:  #{c.after.to_s[-160..].inspect}"
      end
    end
    puts

    if dry_run
      puts "DRY RUN -- nothing written. Re-run with APPLY=1 to repair the stored text."
      next
    end

    FileUtils.mkdir_p(backup_dir)
    repaired = 0
    dirty.each do |step, raw, changes|
      backup = backup_dir.join("pipeline_step_#{step.id}_presafety_#{stamp}.json")
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

      _again, remaining = PipelinePromptSafety.sanitize_workflow(reparsed)
      if remaining.any?
        puts "  ##{step.id} SKIPPED -- #{remaining.size} violation(s) survive the rewrite; backup at #{backup}"
        next
      end

      step.update!(comfy_workflow_json: new_raw)
      repaired += 1
      puts "  ##{step.id} repaired (#{changes.size} rewrite(s)); original backed up to #{backup}"
    end
    puts "repaired #{repaired} of #{dirty.size} step(s)"
  end
end
