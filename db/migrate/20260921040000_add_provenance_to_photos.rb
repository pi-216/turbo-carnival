# frozen_string_literal: true

# Phase 1 of openspec/changes/add-synthetic-provenance (task 1.1).
#
# `synthetic` is deliberately NULLABLE with NO default. Provenance that was never
# tracked must not silently read as human origin, so a row without an explicit
# value means "unknown" -- and a future creation path that forgets to mark a
# render shows up as NULL instead of masquerading as a photograph. The NOT NULL
# constraint is a separate later phase (task 1.4) and lands only once every
# existing row carries an explicit value.
class AddProvenanceToPhotos < ActiveRecord::Migration[8.0]
  def change
    add_column :photos, :synthetic, :boolean
    add_column :photos, :provenance, :jsonb, default: {}
  end
end
