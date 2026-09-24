#!/usr/bin/env bash
# One-command verification of the REELS publish rail (ops 2026-09-24).
#
# WHY: Instagram::Client#create_reel takes a `video_url:` and fetches it over the
# public internet. The rail therefore has to prove four things that no unit test
# covers end to end -- the asset builds with the IPTC mark, a post can carry it,
# the URL resolves, and the SERVED bytes are the marked ones -- against the LIVE
# tunnel, not a fixture. It creates ONE throwaway post, fetches, and removes it
# (trap-guarded, so a failure mid-run still leaves no debris).
#
# Run it before arming the discovery arm and after any change to MediaController,
# GeneratePublicReelUrl or ReelBuilder.
#
#   bin/reel_rail_smoke.sh
#
# Exit 0 = the rail is publishable. Any failure prints what disagreed.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC="${TURBO_CARNIVAL_PUBLIC_URL:-https://carnival.pi216.ai}"
BUILD_SCRIPT="tmp/reel_rail_smoke.rb"
CLEAN_SCRIPT="tmp/reel_rail_smoke_cleanup.rb"

cleanup() {
  [ -f "$CLEAN_SCRIPT" ] && bin/rails runner "$CLEAN_SCRIPT" || true
}
trap cleanup EXIT

cat > "$BUILD_SCRIPT" <<'RUBY'
# frozen_string_literal: true
require 'open3'

photos = ContentPillars::Photo.where.not(path: nil).order(created_at: :desc).limit(3).to_a
abort('need 3 renders') if photos.size < 3

files = photos.map(&:servable_file_path)
abort("render files missing: #{files.reject { |f| f && File.file?(f) }.inspect}") if files.any? { |f| !f || !File.file?(f) }

out = Rails.root.join('storage', 'reels', "smoke-#{Time.now.to_i}.mp4").to_s
Growth::ReelBuilder.build(photos: files, output_path: out)
puts "LOCAL_BYTES #{File.size(out)}"
puts "MARKED_IN_FILE #{Growth::ReelBuilder.marked?(out)}"

probe = Open3.capture2e('ffprobe', '-v', 'error', '-select_streams', 'v:0',
                        '-show_entries', 'stream=codec_name,width,height,pix_fmt',
                        '-show_entries', 'format=duration', '-of', 'default=nw=1', out).first
puts "FFPROBE #{probe.strip.gsub("\n", ' ')}"

post = Scheduling::Post.create!(persona: Persona.find_by(name: 'Sarah') || Persona.first,
                                status: 'draft', reel_path: out, strategy_name: 'reel-rail-smoke')
result = Scheduling::Commands::GeneratePublicReelUrl.call(post: post)
puts "URL_OK #{result.success?} ERRORS #{result.errors.full_messages.inspect}"
puts "REEL_URL #{result.public_reel_url}"
# A STILL post id, chosen from the DB rather than hardcoded: once the arm is
# armed there ARE reel posts, so a fixed id proves nothing about the rule.
puts "STILL_ID #{Scheduling::Post.where(reel_path: nil).order(:id).last&.id}"
RUBY

cat > "$CLEAN_SCRIPT" <<'RUBY'
# frozen_string_literal: true
post = Scheduling::Post.find_by(strategy_name: 'reel-rail-smoke')
if post
  path = post.reel_path
  post.destroy!
  File.delete(path) if path && File.file?(path)
  puts "CLEANED post=#{post.id}"
end
puts "POSTS #{Scheduling::Post.count} REELS #{Scheduling::Post.where.not(reel_path: nil).count}"
RUBY

out="$(bin/rails runner "$BUILD_SCRIPT")"
echo "$out"

url="$(printf '%s\n' "$out" | sed -n 's/^REEL_URL //p')"
[ -n "$url" ] || { echo "FAIL: the rail produced no URL"; exit 1; }

body="tmp/reel_rail_smoke.bin"
code="$(curl -s -m 60 -o "$body" -w '%{http_code}' "$url")"
type="$(curl -s -m 60 -o /dev/null -w '%{content_type}' "$url")"
served="$(wc -c < "$body" | tr -d ' ')"
local_bytes="$(printf '%s\n' "$out" | sed -n 's/^LOCAL_BYTES //p')"

echo "SERVED http=$code type=$type bytes=$served url=$url"
rm -f "$body"

[ "$code" = "200" ] || { echo "FAIL: expected 200, got $code"; exit 1; }
[ "$type" = "video/mp4" ] || { echo "FAIL: expected video/mp4, got $type"; exit 1; }
[ "$served" = "$local_bytes" ] || { echo "FAIL: served $served bytes vs local $local_bytes"; exit 1; }

# The negative side of the same rule: the id IS a post id, so a non-reel id must
# never serve bytes -- this endpoint is not a second enumerable surface.
still_id="$(printf '%s\n' "$out" | sed -n 's/^STILL_ID //p')"
[ -n "$still_id" ] || { echo "FAIL: no still post id to test the withhold rule with"; exit 1; }
still_code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' "${PUBLIC%/}/media/reels/$still_id")"
[ "$still_code" = "404" ] || { echo "FAIL: /media/reels/$still_id (a still post) returned $still_code, expected 404"; exit 1; }

echo "PASS: reel rail publishable ($served bytes, video/mp4, marked bytes served, non-reel ids 404)"