# frozen_string_literal: true

namespace :post_automation do
  desc "Automatically create and schedule the next post for a persona"
  task :create_next, [ :persona_name ] => :environment do |_t, args|
    persona_name = args[:persona_name] || ENV["PERSONA"]

    unless persona_name
      puts "❌ Error: Please provide a persona name"
      puts "Usage: bin/rails post_automation:create_next[persona_name]"
      puts "   or: PERSONA=persona_name bin/rails post_automation:create_next"
      exit 1
    end

    persona = Persona.find_by(name: persona_name)

    unless persona
      puts "❌ Error: Persona '#{persona_name}' not found"
      exit 1
    end

    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "  Auto Post Creator"
    puts "  Persona: #{persona.name}"
    puts "  Time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts

    result = PostAutomation::AutoCreateNextPost.call(persona: persona)

    if result.success?
      puts "✅ Successfully created scheduled post!"
      puts
      puts "📸 Photo ID: #{result.photo.id}"
      puts "📁 Pillar: #{result.pillar&.name || 'N/A'}"
      puts "🎯 Strategy: #{result.strategy_name}"
      puts "📝 Caption: #{result.caption[0..80]}#{result.caption.length > 80 ? '...' : ''}"
      puts "⏰ Scheduled for: #{result.post.scheduled_at.strftime('%Y-%m-%d %H:%M %Z')}"
      puts "🆔 Post ID: #{result.post.id}"
      puts
      puts "View at: http://localhost:3003/personas/#{persona.id}/scheduling/posts"
    else
      puts "❌ Failed to create post"
      puts "Error: #{result.full_error_message}"
      exit 1
    end

    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  end

  desc "Automatically create and schedule posts for all personas"
  task create_for_all: :environment do
    Persona.find_each do |persona|
      puts "\n🤖 Processing #{persona.name}..."

      result = PostAutomation::AutoCreateNextPost.call(persona: persona)

      if result.success?
        puts "  ✅ Post created and scheduled for #{result.post.scheduled_at.strftime('%H:%M %Z')}"
      else
        puts "  ⚠️  Skipped: #{result.full_error_message}"
      end
    end

    puts "\n✅ Done!"
  end
end
