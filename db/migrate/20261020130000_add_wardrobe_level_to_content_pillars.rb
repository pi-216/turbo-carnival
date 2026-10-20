class AddWardrobeLevelToContentPillars < ActiveRecord::Migration[8.0]
  # PRD 0007 A2 (#105): wardrobe intensity becomes a per-pillar axis the brain
  # controls, replacing the removed `PillarPrompt::SAFE_BASE` modest-clothing
  # floor. `wardrobe_level` is the pillar's rung on ContentPillars::WardrobeAxis
  # (1-based). NULL = unconfigured: the render falls back to the axis floor
  # (the covered rung), which is a RUNG on the scale the brain can raise — not a
  # hardcoded SFW constraint.
  #
  # The check constraint is a loose DB backstop only (positive, sane range); the
  # precise bound (1..the current validated tier) is enforced in Ruby (the model
  # validates the scale; the growth layer enforces the tier ceiling). Added
  # unvalidated here and validated in the follow-up migration, per
  # strong_migrations (a CHECK on an existing table must not block the write).
  def change
    add_column :content_pillars, :wardrobe_level, :integer

    add_check_constraint :content_pillars,
                         'wardrobe_level IS NULL OR (wardrobe_level >= 1 AND wardrobe_level <= 100)',
                         name: 'wardrobe_level_range_check',
                         validate: false
  end
end
