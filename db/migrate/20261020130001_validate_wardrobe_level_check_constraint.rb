class ValidateWardrobeLevelCheckConstraint < ActiveRecord::Migration[8.0]
  # Strong_migrations follow-up to AddWardrobeLevelToContentPillars: now that
  # the unvalidated check constraint is in place, validate it against the
  # existing rows. content_pillars is a small table, so this is instant.
  def change
    validate_check_constraint :content_pillars, name: 'wardrobe_level_range_check'
  end
end
