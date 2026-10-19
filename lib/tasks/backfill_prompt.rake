namespace :pipeline_runs do
  desc "Backfill prompt column from variables['prompt']"
  task backfill_prompt: :environment do
    puts "Starting backfill of prompt column from variables..."

    updated_count = 0
    skipped_count = 0

    PipelineRun.find_each do |run|
      if run.variables.is_a?(Hash) && run.variables["prompt"].present?
        run.update_column(:prompt, run.variables["prompt"])
        updated_count += 1
        puts "  Updated run ##{run.id}: prompt = '#{run.prompt}'"
      else
        skipped_count += 1
      end
    end

    puts "\nBackfill complete!"
    puts "  Updated: #{updated_count} runs"
    puts "  Skipped: #{skipped_count} runs (no prompt in variables)"
  end

  desc "Remove prompt and run_name from variables JSONB column"
  task cleanup_variables: :environment do
    puts "Starting cleanup of prompt and run_name from variables..."

    cleaned_count = 0

    PipelineRun.find_each do |run|
      if run.variables.is_a?(Hash) && (run.variables.key?("prompt") || run.variables.key?("run_name"))
        new_vars = run.variables.except("prompt", "run_name")
        run.update_column(:variables, new_vars)
        cleaned_count += 1
        puts "  Cleaned run ##{run.id}"
      end
    end

    puts "\nCleanup complete!"
    puts "  Cleaned: #{cleaned_count} runs"
  end
end
