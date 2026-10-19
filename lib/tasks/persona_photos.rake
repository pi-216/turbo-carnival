# frozen_string_literal: true

namespace :personas do
  desc "Download all photos for a persona to a folder (persona_id, target_dir)"
  task :download_photos, %i[persona_id target_dir] => :environment do |_t, args|
    require "fileutils"

    persona_id = args[:persona_id].to_i
    target_dir = args[:target_dir].to_s

    raise ArgumentError, "persona_id is required" if persona_id <= 0
    raise ArgumentError, "target_dir is required" if target_dir.empty?

    persona = Persona.find(persona_id)

    FileUtils.mkdir_p(target_dir)
    raise "Target path is not a directory: #{target_dir}" unless File.directory?(target_dir)

    photos = persona.photos.includes(image_attachment: :blob).order(:id)

    puts "Downloading #{photos.size} photos for Persona##{persona.id} (#{persona.name})"
    puts "Target: #{target_dir}"

    downloaded = 0
    skipped = 0

    photos.find_each do |photo|
      filename = if photo.image.attached?
        photo.image.filename.to_s
      else
        File.basename(photo.path.to_s)
      end

      filename = "image" if filename.empty?
      filename = filename.gsub(/[^0-9A-Za-z.\-_]+/, "_")

      target_path = File.join(target_dir, "#{photo.id}_#{filename}")
      if File.exist?(target_path)
        skipped += 1
        puts "- Skipping Photo##{photo.id} (already exists): #{target_path}"
        next
      end

      if photo.image.attached?
        photo.image.open do |io|
          IO.copy_stream(io, target_path)
        end
        downloaded += 1
        puts "- Wrote Photo##{photo.id} -> #{target_path}"
      elsif photo.path.present? && File.exist?(photo.path)
        FileUtils.cp(photo.path, target_path)
        downloaded += 1
        puts "- Copied Photo##{photo.id} -> #{target_path}"
      else
        skipped += 1
        puts "- Skipping Photo##{photo.id} (no attached image, missing path: #{photo.path.inspect})"
      end
    end

    puts "Done. Downloaded: #{downloaded}, Skipped: #{skipped}"
  end
end
