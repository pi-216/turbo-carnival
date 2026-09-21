# frozen_string_literal: true

namespace :photos do
  desc 'Mark the pre-existing photo corpus synthetic ' \
       '(dry-run by default; APPLY=1 to write)'
  task backfill_provenance: :environment do
    # WHY THIS EXISTS
    # Provenance was never tracked at creation, so the whole corpus predates the
    # mark (openspec/changes/add-synthetic-provenance, task 1.2). Every photo
    # here came out of a render, so it is marked synthetic -- with
    # provenance.embedded=false, because what was NOT recorded is that the asset
    # carries a machine-readable mark (a later phase of the same change). A row is
    # never defaulted to human origin: until this runs, `synthetic` is NULL and
    # reads as unknown. DRY RUN by default because it writes production rows.
    apply = ENV['APPLY'].to_s == '1'
    scope = ContentPillars::Photo.where(synthetic: nil)
    total = scope.count

    puts "photos:backfill_provenance: #{total} photo(s) without a synthetic mark " \
         "(corpus #{ContentPillars::Photo.count})"

    if total.zero?
      puts 'nothing to do.'
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
end
