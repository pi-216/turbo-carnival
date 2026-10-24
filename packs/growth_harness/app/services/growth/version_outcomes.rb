# frozen_string_literal: true

module Growth
  # What each content config VERSION earned -- #40 criterion 3: "two versions' outcomes are
  # comparable by query".
  #
  # The chain is NOT re-written here. `Growth::RenderReach` owns it (render -> candidate ->
  # photo -> post) and this reads that ONE chain, grouped by the version each render
  # referenced. A second copy of those joins is how two answers about the same assets start
  # disagreeing.
  #
  # The comparison is the point: a version is the address a metric shift has, so "which config
  # earned the reach" and "did the change help" are the same query at different group-by
  # levels. Reels and unpublished renders stay ABSENT from the reach side of the read rather
  # than being attributed to a guess -- `RenderReach`'s rule, inherited here.
  #
  # ABSENCE STAYS ABSENCE. A version whose renders have no measured reach reports NULL, never
  # 0: a zero would read as "this config earned nothing", which is a different fact from
  # "nothing has been measured yet". A version that has never been rendered reports
  # `render_count` 0 with NULL reach, so it is visibly unrendered instead of tying at zero.
  class VersionOutcomes
    Row = Struct.new(:version_id, :digest, :render_count, :post_count, :reach, :views,
                     keyword_init: true)

    def self.call(reach_rows: Growth::RenderReach.call)
      versions = Attribution::ContentConfigVersion.order(:id).pluck(:id, :digest)
      render_counts = Attribution::Render.where.not(content_config_version_id: nil)
                                         .group(:content_config_version_id).count
      version_of_render = Attribution::Render.where.not(content_config_version_id: nil)
                                             .pluck(:id, :content_config_version_id).to_h

      totals = reach_by_version(reach_rows, version_of_render)

      versions.map do |version_id, digest|
        bucket = totals[version_id] || {}

        Row.new(version_id: version_id, digest: digest,
                render_count: render_counts.fetch(version_id, 0),
                post_count: bucket.fetch(:post_count, 0),
                reach: bucket[:reach], views: bucket[:views])
      end
    end

    # Sums the per-render reach rows into their version. `row.reach` is already NULL for a
    # render whose posts carry no measurement, so the sum stays NULL until something is
    # actually measured.
    def self.reach_by_version(reach_rows, version_of_render)
      reach_rows.each_with_object({}) do |row, totals|
        version_id = version_of_render[row.render_id]
        next if version_id.nil?

        bucket = totals[version_id] ||= { post_count: 0, reach: nil, views: nil }
        bucket[:post_count] += row.post_count.to_i
        bucket[:reach] = bucket[:reach].to_i + row.reach.to_i if row.reach
        bucket[:views] = bucket[:views].to_i + row.views.to_i if row.views
      end
    end
  end
end
