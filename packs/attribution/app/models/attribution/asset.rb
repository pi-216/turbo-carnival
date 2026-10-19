# frozen_string_literal: true

module Attribution
  # One row per distinct produced media file, content-addressed on `sha256`.
  #
  # WHY sha256 is the key: it is the join key that already exists across tools -- elo-picker
  # keys its own `images` table on sha256, and engagement attaches to a published asset. That
  # is what turns "which inputs produced the assets that earned the most reach" into one
  # query rather than a manual reconstruction.
  #
  # `path` is a LOCATION, not an identity: a re-render overwrites the same file, so one path
  # legitimately describes different content at different times. Identity is the hash, which
  # is why it is unique and the path is not.
  #
  # Nothing here is derived from `photos.provenance` -- that column is the synthetic-mark
  # COMPLIANCE ledger (the legal floor) and stays a separate record.
  class Asset < ApplicationRecord
    self.table_name = "assets"

    KINDS = %w[image video].freeze
    SHA256_FORMAT = /\A[0-9a-f]{64}\z/

    has_many :renders, class_name: "Attribution::Render", dependent: :nullify, inverse_of: :asset
    has_many :assessments, through: :renders, class_name: "Attribution::Assessment"

    validates :sha256, presence: true, uniqueness: true, format: { with: SHA256_FORMAT }
    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :width, :height, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    # Idempotent content addressing: the same bytes resolve to the same row however many
    # renders produced them, so a re-render cannot fork one asset into two.
    #
    # Facts are FILLED IN when they become known and never invented: a nil argument leaves
    # whatever is already recorded alone.
    def self.record(sha256:, **attrs)
      asset = find_or_initialize_by(sha256: sha256)
      attrs.each { |name, value| asset[name.to_s] = value unless value.nil? }
      asset.save!
      asset
    end

    # Absent is a normal state, not an error: content that was never recorded reads as nil.
    def self.for_sha256(digest)
      find_by(sha256: digest)
    end

    def self.for_path(path)
      find_by(path: path)
    end
  end
end
