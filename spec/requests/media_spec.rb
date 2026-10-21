# frozen_string_literal: true

require 'rails_helper'

# B5 (PRD 0007): the tunnel media endpoint serves a photo's bytes only while a
# post for it is in the QUEUE or already PUBLISHED. Every other selection state
# -- a HELD post (a pre-publish gate cleared both publisher clocks while keeping
# the row), a post that was never queued, a failed post, a purged post (row
# deleted), or a render no post references -- 404s, NOT 403, so the platform
# never learns the asset exists. Nothing is deleted: held/flagged bytes stay on
# disk and in the corpus for re-valuation (A1 retention); only their public URL
# goes away.
#
# This spec IS the state -> HTTP-behaviour matrix the ticket requires. A held
# fixture is built the way the gates build one: status kept, BOTH publisher
# clocks cleared, and a hold marker in caption_metadata (the marker is there for
# fidelity -- the endpoint keys off the cleared clocks, not the metadata).
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

  # A post for `photo` in the given state. The gates' hold is reproduced
  # faithfully: status kept, both publisher clocks cleared, a hold marker in
  # caption_metadata. (A bare `status:` with no slot is the old, pre-B5 fixture
  # that B5 demotes to :held.)
  def post_for(photo, attrs)
    Scheduling::Post.create!(persona: persona, photo: photo, **attrs)
  end

  describe 'GET /media/photos/:id -- selection state -> HTTP' do
    future_slot = 1.hour.from_now
    overdue_slot = 1.hour.ago

    # :published or :queued -> the platform fetches these at publish time.
    served_states = [
      [ 'published (status posted)',       { status: 'posted' } ],
      [ 'published (provider post id)',    { status: 'scheduled', provider_post_id: 'IG-123' } ],
      [ 'queued (scheduled, future slot)', { status: 'scheduled', scheduled_at: future_slot } ],
      [ 'queued (scheduled, overdue slot)', { status: 'scheduled', scheduled_at: overdue_slot } ],
      [ 'queued (draft, optimal time set)', { status: 'draft', optimal_time_calculated: future_slot } ],
      [ 'queued (posting, slot)',          { status: 'posting', scheduled_at: future_slot } ]
    ]
    served_states.each do |label, attrs|
      it "serves a photo that is #{label}" do
        photo, path = photo_with_bytes
        post_for(photo, attrs)

        get media_photo_path(photo)

        expect(response).to have_http_status(:success)
        expect(response.body).to eq('fake image data')
      ensure
        FileUtils.rm_f(path)
      end
    end

    # :held -> 404 (not 403), bytes left on disk.
    withheld_states = [
      [ 'held (age gate, clocks cleared)',    { status: 'scheduled', caption_metadata: { 'age_gate' => { 'held' => true, 'outcome' => 'held' } } } ],
      [ 'held (near-dup gate, clocks cleared)', { status: 'draft', caption_metadata: { 'near_dup_gate' => { 'held' => true, 'outcome' => 'held' } } } ],
      [ 'never queued (draft, no slot)',      { status: 'draft' } ],
      [ 'scheduled, both clocks cleared',     { status: 'scheduled' } ],
      [ 'failed (slot retained)',             { status: 'failed', scheduled_at: future_slot } ],
      [ 'awaiting an image',                  { status: 'awaiting_image' } ]
    ]
    withheld_states.each do |label, attrs|
      it "404s (withholds) a photo that is #{label}" do
        photo, path = photo_with_bytes
        post_for(photo, attrs)

        get media_photo_path(photo)

        expect(response).to have_http_status(:not_found)
        expect(File.exist?(path)).to be(true) # nothing is deleted
      ensure
        FileUtils.rm_f(path)
      end
    end

    it '404s a render no post references, even though the bytes are on disk' do
      photo, path = photo_with_bytes

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
      expect(File.exist?(path)).to be(true)
    ensure
      FileUtils.rm_f(path)
    end

    it '404s a photo whose only post was purged (row deleted, photo + bytes kept)' do
      photo, path = photo_with_bytes
      post = post_for(photo, status: 'scheduled', scheduled_at: future_slot)
      post.destroy! # what a purge does: post gone, photo + bytes remain

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
      expect(File.exist?(path)).to be(true)
    ensure
      FileUtils.rm_f(path)
    end

    it 'still 404s a queued photo whose bytes are gone' do
      photo = photo_at('/nonexistent/withheld.png')
      post_for(photo, status: 'scheduled', scheduled_at: future_slot)

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    end

    it '404s a photo path that resolves outside the serving roots' do
      path = File.join(mirror_root, '..', '..', 'etc', 'passwd')
      photo = photo_at(path)
      post_for(photo, status: 'scheduled', scheduled_at: future_slot)

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    end

    it '404s a photo id that does not exist' do
      get media_photo_path(999_999)

      expect(response).to have_http_status(:not_found)
    end
  end

  # The REELS rail's serving step: `Instagram::Client#create_reel` takes a
  # `video_url:`, and before this endpoint existed nothing served a video at all
  # (the pivot's machinery was built but uncallable). The id IS a post id, so the
  # same selection-state rule applies to the row that owns the bytes.
  describe 'GET /media/reels/:id -- selection state -> HTTP' do
    REEL_DIR = Rails.root.join('storage/reels')

    future_slot = 1.hour.from_now
    overdue_slot = 1.hour.ago

    def reel_bytes
      FileUtils.mkdir_p(REEL_DIR)
      path = File.join(REEL_DIR, "media_spec-#{SecureRandom.hex(4)}.mp4")
      File.write(path, 'fake video bytes')
      path
    end

    def reel_post(path, attrs)
      Scheduling::Post.create!(persona: persona, reel_path: path, **attrs)
    end

    served_states = [
      [ 'published (status posted)',       { status: 'posted' } ],
      [ 'published (provider post id)',    { status: 'scheduled', provider_post_id: 'IG-123' } ],
      [ 'queued (scheduled, future slot)', { status: 'scheduled', scheduled_at: future_slot } ],
      [ 'queued (scheduled, overdue slot)', { status: 'scheduled', scheduled_at: overdue_slot } ],
      [ 'queued (posting, slot)',          { status: 'posting', scheduled_at: future_slot } ]
    ]
    served_states.each do |label, attrs|
      it "serves the MP4 of a reel post that is #{label}" do
        path = reel_bytes
        post = reel_post(path, attrs)

        get media_reel_path(post)

        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq('video/mp4')
        expect(response.body).to eq('fake video bytes')
      ensure
        FileUtils.rm_f(path)
      end
    end

    withheld_states = [
      [ 'held (age gate, clocks cleared)',    { status: 'scheduled', caption_metadata: { 'age_gate' => { 'held' => true, 'outcome' => 'held' } } } ],
      [ 'held (near-dup gate, clocks cleared)', { status: 'draft', caption_metadata: { 'near_dup_gate' => { 'held' => true, 'outcome' => 'held' } } } ],
      [ 'never queued (draft, no slot)',      { status: 'draft' } ],
      [ 'scheduled, both clocks cleared',     { status: 'scheduled' } ],
      [ 'failed (slot retained)',             { status: 'failed', scheduled_at: future_slot } ]
    ]
    withheld_states.each do |label, attrs|
      it "404s (withholds) a reel post that is #{label}" do
        path = reel_bytes
        post = reel_post(path, attrs)

        get media_reel_path(post)

        expect(response).to have_http_status(:not_found)
        expect(File.exist?(path)).to be(true) # nothing is deleted
      ensure
        FileUtils.rm_f(path)
      end
    end

    it 'withholds a reel whose post is gone (row deleted)' do
      path = reel_bytes
      post = reel_post(path, status: 'scheduled', scheduled_at: future_slot)
      post.destroy!

      get "/media/reels/#{post.id}"

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(path)
    end

    it 'is not an enumerable second surface: a still post id serves nothing' do
      photo, spath = photo_with_bytes
      still = post_for(photo, status: 'scheduled', scheduled_at: future_slot)

      get media_reel_path(still)

      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(spath)
    end

    it '404s a reel whose bytes are gone' do
      post = reel_post('/nonexistent/reel.mp4', status: 'scheduled', scheduled_at: future_slot)

      get media_reel_path(post)

      expect(response).to have_http_status(:not_found)
    end

    it '404s a reel path that resolves outside storage/reels' do
      path = File.join(REEL_DIR, '..', '..', '..', 'etc', 'passwd')
      post = reel_post(path, status: 'scheduled', scheduled_at: future_slot)

      get media_reel_path(post)

      expect(response).to have_http_status(:not_found)
    end
  end
end
