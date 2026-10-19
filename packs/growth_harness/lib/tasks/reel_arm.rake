# frozen_string_literal: true

namespace :growth do
  # ARM the pre-registered discovery pivot: build ONE reel post from renders the
  # harness already produced and queue it for the reel rail
  # (scheduling:post_reels). This is the asset+record step -- it publishes
  # nothing, so it is safe to run and inspect before the external write.
  #
  #   bundle exec rails growth:reel_arm[Sarah]              # build + queue one reel
  #   bundle exec rails growth:reel_arm[Sarah,PHOTOS=6]     # use 6 source renders
  #   bundle exec rails growth:reel_arm[Sarah,CAPTION='...']# override the caption
  #
  # It refuses when an unpublished reel post already exists (see
  # Growth::ReelArm#guard_no_pending_reel!), so re-running cannot stack up
  # external writes.
  desc 'Build one reel post from existing renders and queue it for the reel rail (PHOTOS=N, CAPTION=text)'
  task :reel_arm, [ :persona_name ] => :environment do |_t, args|
    name = args[:persona_name].presence || ENV['PERSONA'].presence || 'Sarah'
    persona = Persona.find_by(name: name)
    abort("growth:reel_arm: no persona named #{name.inspect}") if persona.nil?

    photos = (ENV['PHOTOS'] || Growth::ReelArm::SOURCE_PHOTOS).to_i

    begin
      result = Growth::ReelArm.new(persona: persona, photo_count: photos, caption: ENV['CAPTION']).call
    rescue Growth::ReelArm::Error => e
      abort("growth:reel_arm: #{e.message}")
    end

    puts "reel arm: post #{result[:post_id]} queued from renders #{result[:source_photo_ids].join(', ')}"
    puts "  reel_path: #{result[:reel_path]}"
    puts "  bytes: #{result[:bytes]}"
    puts "  marked: #{Growth::ReelBuilder.marked?(result[:reel_path])}"
    puts "  publish it with: bundle exec rails scheduling:post_reels"
  end
end
