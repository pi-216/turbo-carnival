# frozen_string_literal: true

namespace :personas do
  desc "Import Sarah persona from fluffy-train and assign all runs to her"
  task import_sarah: :environment do
    puts "Importing Sarah persona from fluffy-train..."

    # Simpler approach: query directly using cross-database query
    # Assuming both DBs are in same PostgreSQL instance
    begin
      result = ActiveRecord::Base.connection.execute(<<-SQL)
        SELECT name, caption_config, hashtag_strategy
        FROM fluffy_train_development.personas
        WHERE name = 'Sarah'
        LIMIT 1
      SQL

      if result.count == 0
        puts "❌ Sarah persona not found in fluffy-train database"
        puts "Creating Sarah with default values..."
        sarah = Persona.create!(name: "Sarah")
      else
        sarah_data = result.first
        sarah = Persona.find_or_initialize_by(name: "Sarah")

        # Handle JSONB data carefully
        if sarah_data["caption_config"].present? && sarah_data["caption_config"] != "{}"
          sarah[:caption_config] = sarah_data["caption_config"]
        end

        if sarah_data["hashtag_strategy"].present? && sarah_data["hashtag_strategy"] != "{}"
          sarah[:hashtag_strategy] = sarah_data["hashtag_strategy"]
        end

        sarah.save!
        puts "✅ Sarah persona imported (ID: #{sarah.id})"
      end
    rescue ActiveRecord::StatementInvalid => e
      puts "⚠️  Could not query fluffy-train database (#{e.message})"
      puts "Creating Sarah with default values..."
      sarah = Persona.find_or_create_by!(name: "Sarah")
    end

    # Assign all pipeline runs to Sarah
    run_count = PipelineRun.where(persona_id: nil).count
    puts "Assigning #{run_count} pipeline runs to Sarah..."

    PipelineRun.where(persona_id: nil).update_all(persona_id: sarah.id)

    puts "✅ All #{run_count} runs now belong to Sarah"
    puts ""
    puts "Summary:"
    puts "  - Sarah ID: #{sarah.id}"
    puts "  - Total runs: #{PipelineRun.count}"
    puts "  - Sarah's runs: #{PipelineRun.where(persona_id: sarah.id).count}"
  end
end
