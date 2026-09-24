# frozen_string_literal: true

# The publishable asset path for a REELS post.
#
# WHY THIS COLUMN EXISTS (ops decision 2026-09-24, the pre-registered pivot).
# Instagram::Client#create_reel was built to publish to the one surface with
# non-follower distribution, and it takes a `video_url:` -- but the rail had no
# way to PRODUCE one: MediaController#photo serves `image/png` for a
# ContentPillars::Photo and nothing served a video, so the pivot's last step was
# uncallable. Measured 2026-09-24: zero production callers of create_reel, and
# grep for a video route/endpoint finds none.
#
# The column is the same shape the still path uses: the URL is minted from the
# POST at publish time (Scheduling::Commands::GeneratePublicReelUrl) and is a
# passthrough to this PATH, so the bytes Meta fetches are the bytes the
# provenance gate checked.
#
# NULL means "a still post", which is the meaning every existing row keeps: the
# column is additive and no still-path query is changed by it.
class AddReelPathToSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :reel_path, :string
  end
end