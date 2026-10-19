# frozen_string_literal: true

require 'rails_helper'

# MediaController#photo is a PUBLIC byte server (the Cloudflare tunnel fronts
# it) that takes a SEQUENTIAL id, so everything it answers for is enumerable.
# The withhold rule is: bytes are served only while a post references the photo.
# Measured 2026-09-23 before the fix: GET /media/photos/241 -> 200, a photo whose
# post had been purged by the NSFW gate (post row deleted, Photo row kept).
#
# Since 2026-10-13 the byte servers only serve a DB-stored path after proving it
# stays inside the root its writer mints into (Brakeman SendFile/Medium 3.x), so
# the fixtures below are written into those roots -- COMFYUI_MIRROR_ROOT for the
# still path, Rails.root/storage/reels/ for the reel path -- not system /tmp.
RSpec.describe 'Media', type: :request do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  around do |example|
    Dir.mktmpdir('media-root') do |dir|
      @mirror_root = dir
      old = ENV['COMFYUI_MIRROR_ROOT']
      ENV['COMFYUI_MIRROR_ROOT'] = dir
      example.run
      old.nil? ? ENV.delete('COMFYUI_MIRROR_ROOT') : ENV['COMFYUI_MIRROR_ROOT'] = old
    end
  end

  attr_reader :mirror_root

  def photo_with_bytes
    path = File.join(mirror_root, 'media_spec.png')
    File.write(path, 'fake image data')
    [ photo_at(path), path ]
  end

  def photo_at(path)
    ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: path)
  end

  describe 'GET /media/photos/:id' do
    it 'serves a photo the publishing path can still ask for' do
      photo, path = photo_with_bytes
      Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_photo_path(photo)

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('fake image data')
    ensure
      FileUtils.rm_f(path)
    end

    it 'withholds a render no post references, even though the bytes are on disk' do
      photo, path = photo_with_bytes

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(path)
    end

    it 'withholds a photo whose only post was purged (row deleted, Photo kept)' do
      photo, path = photo_with_bytes
      post = Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')
      post.destroy! # what the nsfw_purge path did: post gone, photo + bytes remain

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(path)
    end

    it 'still 404s a posted photo whose bytes are gone' do
      photo = photo_at('/nonexistent/withheld.png')
      Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    end

    it '404s a photo path that resolves outside the serving roots' do
      path = File.join(mirror_root, '..', '..', 'etc', 'passwd')
      photo = photo_at(path)
      Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    end
  end

  # The REELS rail's serving step: `Instagram::Client#create_reel` takes a
  # `video_url:`, and before this endpoint existed nothing served a video at all
  # (the pivot's machinery was built but uncallable).
  describe 'GET /media/reels/:id' do
    REEL_DIR = Rails.root.join('storage/reels')

    def reel_post_at(path)
      Scheduling::Post.create!(persona: persona, status: 'scheduled', reel_path: path)
    end

    def reel_bytes
      FileUtils.mkdir_p(REEL_DIR)
      path = File.join(REEL_DIR, "media_spec-#{SecureRandom.hex(4)}.mp4")
      File.write(path, 'fake video bytes')
      path
    end

    it 'serves the MP4 of a reel post as video/mp4' do
      path = reel_bytes
      post = reel_post_at(path)

      get media_reel_path(post)

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('video/mp4')
      expect(response.body).to eq('fake video bytes')
    ensure
      FileUtils.rm_f(path)
    end

    it 'withholds a reel whose post is gone (the still path rule, keyed on the post)' do
      path = reel_bytes
      post = reel_post_at(path)
      post.destroy!

      get "/media/reels/#{post.id}"

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(path)
    end

    it 'is not an enumerable second surface: a still post id serves nothing' do
      photo, path = photo_with_bytes
      still = Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_reel_path(still)

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(path)
    end

    it '404s a reel whose bytes are gone' do
      post = reel_post_at('/nonexistent/reel.mp4')

      get media_reel_path(post)

      expect(response).to have_http_status(:not_found)
    end

    it '404s a reel path that resolves outside storage/reels' do
      path = File.join(REEL_DIR, '..', '..', '..', 'etc', 'passwd')
      post = reel_post_at(path)

      get media_reel_path(post)

      expect(response).to have_http_status(:not_found)
    end
  end
end
