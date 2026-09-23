# frozen_string_literal: true

require 'rails_helper'

# MediaController#photo is a PUBLIC byte server (the Cloudflare tunnel fronts
# it) that takes a SEQUENTIAL id, so everything it answers for is enumerable.
# The withhold rule is: bytes are served only while a post references the photo.
# Measured 2026-09-23 before the fix: GET /media/photos/241 -> 200, a photo whose
# post had been purged by the NSFW gate (post row deleted, Photo row kept).
RSpec.describe 'Media', type: :request do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def photo_with_bytes
    file = Tempfile.new(['media_spec', '.png'])
    file.write('fake image data')
    file.close
    [photo_at(file.path), file]
  end

  def photo_at(path)
    ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: path)
  end

  describe 'GET /media/photos/:id' do
    it 'serves a photo the publishing path can still ask for' do
      photo, file = photo_with_bytes
      Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_photo_path(photo)

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('fake image data')
    ensure
      file&.unlink
    end

    it 'withholds a render no post references, even though the bytes are on disk' do
      photo, file = photo_with_bytes

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    ensure
      file&.unlink
    end

    it 'withholds a photo whose only post was purged (row deleted, Photo kept)' do
      photo, file = photo_with_bytes
      post = Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')
      post.destroy! # what the nsfw_purge path did: post gone, photo + bytes remain

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    ensure
      file&.unlink
    end

    it 'still 404s a posted photo whose bytes are gone' do
      photo = photo_at('/nonexistent/withheld.png')
      Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')

      get media_photo_path(photo)

      expect(response).to have_http_status(:not_found)
    end
  end
end