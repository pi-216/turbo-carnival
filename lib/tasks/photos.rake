# frozen_string_literal: true

namespace :photos do
  desc "Mark the pre-existing photo corpus synthetic " \
       "(dry-run by default; APPLY=1 to write)"
  task backfill_provenance: :environment do
    # WHY THIS EXISTS
    # Provenance was never tracked at creation, so the whole corpus predates the
    # mark (openspec/changes/add-synthetic-provenance, task 1.2). Every photo
    # here came out of a render, so it is marked synthetic -- with
    # provenance.embedded=false, because what was NOT recorded is that the asset
    # carries a machine-readable mark (a later phase of the same change). A row is
    # never defaulted to human origin: until this runs, `synthetic` is NULL and
    # reads as unknown. DRY RUN by default because it writes production rows.
    apply = ENV["APPLY"].to_s == "1"
    scope = ContentPillars::Photo.where(synthetic: nil)
    total = scope.count

    puts "photos:backfill_provenance: #{total} photo(s) without a synthetic mark " \
         "(corpus #{ContentPillars::Photo.count})"

    if total.zero?
      puts "nothing to do."
      next
    end

    unless apply
      scope.order(:id).limit(3).each { |photo| puts "   - photo #{photo.id} #{photo.path}" }
      puts "DRY RUN -- nothing written. Re-run with APPLY=1 to mark these #{total} photo(s)."
      next
    end

    marked = 0
    scope.find_each do |photo|
      # update_columns: a backfill is metadata about a row that already exists,
      # so it must not bump updated_at (other queries read recency) and must not
      # re-run validations over 300+ historical rows.
      photo.update_columns(synthetic: true, provenance: ContentPillars::PhotoProvenance.backfilled)
      marked += 1
    end

    remaining = ContentPillars::Photo.where(synthetic: nil).count
    puts "APPLIED: marked=#{marked} remaining_unmarked=#{remaining}"
    exit 1 if remaining.positive?
  end

  desc "Write the machine-readable synthetic mark into photo asset bytes " \
       "(dry-run by default; APPLY=1 to write; PHOTO_ID=n or LIMIT=n to scope)"
  task embed_provenance: :environment do
    # WHY THIS EXISTS
    # Tasks 2.1/2.2 of openspec/changes/add-synthetic-provenance: the mark has to
    # be in the bytes Meta fetches, and the served URL is a passthrough to the
    # photo's own file. Renders imported through ContentPillars::Photo.import_render
    # are marked at creation; this task covers the corpus that predates it, one
    # file at a time, reporting per-photo verdicts. DRY RUN by default because it
    # rewrites production assets.
    #
    # The verdict comes from PhotoAssetMarker on the real file (never assumed),
    # and `provenance.embedded=true` is only written when the bytes were read back
    # as carrying the mark.
    apply = ENV["APPLY"].to_s == "1"
    scope = ContentPillars::Photo.order(:id)
    scope = scope.where(id: ENV["PHOTO_ID"].to_i) if ENV["PHOTO_ID"].present?
    scope = scope.limit(ENV["LIMIT"].to_i) if ENV["LIMIT"].present?

    pending = scope.reject { |photo| photo.provenance.to_h["embedded"] == true }
    puts "photos:embed_provenance: #{pending.size} photo(s) to consider " \
         "(corpus #{ContentPillars::Photo.count})"

    if pending.empty?
      puts "nothing to do."
      next
    end

    unless apply
      pending.first(3).each do |photo|
        file = photo.servable_file_path
        state = file ? (ContentPillars::PhotoAssetMarker.marked?(file) ? "already marked" : "unmarked") : "NO SERVABLE FILE"
        puts "   - photo #{photo.id} #{state} #{file}"
      end
      puts "DRY RUN -- nothing written. Re-run with APPLY=1 to mark these #{pending.size} photo(s)."
      next
    end

    tally = Hash.new(0)
    pending.each { |photo| tally[photo.mark_synthetic_asset!] += 1 }

    puts "APPLIED: #{tally.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    still = ContentPillars::Photo.where(synthetic: true)
                                .select { |p| p.provenance.to_h["embedded"] != true }.size
    puts "verified: #{ContentPillars::Photo.count - still} of #{ContentPillars::Photo.count} photo(s) now carry embedded=true"
    exit 1 if tally[:error].positive?
  end
end
