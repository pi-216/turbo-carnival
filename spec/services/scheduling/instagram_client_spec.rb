# frozen_string_literal: true

require 'rails_helper'

# Publishing must survive Instagram's own "FINISHED means almost ready" answer.
#
# Root cause pinned here: the client asked for the container status, read
# status_code=FINISHED, and published immediately -- and Instagram answered
# 400 code 9007 / subcode 2207027 "The media is not ready for publishing, please
# wait for a moment". Measured 2026-09-20 on post 333: container create + status
# check + publish all completed inside ~5s, so the FINISHED answer is optimistic.
# The publisher then marked the post failed with no requeue, so a transient API
# state cost a whole slot AND its photo (3rd lifetime occurrence: posts 37, 246,
# 333). The retry is safe by construction: 9007 means the container was NOT
# published, and media containers are single-use, so a retry cannot double-post.
RSpec.describe Instagram::Client do
  let(:client) { described_class.new }

  def response(status, body)
    double('response', status: status, body: body, success?: (200..299).cover?(status))
  end

  def ok(body)
    response(200, body)
  end

  def media_not_ready
    response(400, { 'error' => { 'message' => 'Media ID is not available',
                                 'type' => 'OAuthException',
                                 'code' => 9007,
                                 'error_subcode' => 2207027,
                                 'error_user_msg' => 'The media is not ready for publishing, please wait for a moment' } })
  end

  # Drives the REAL call order: container create (POST) -> status check (GET) ->
  # publish (POST). The request object is handed to the block exactly as Faraday
  # does, so the parameters the client sets are exercised too.
  def stub_flow(responses)
    queue = responses.dup
    request = Struct.new(:params).new({})
    connection = double('faraday')
    allow(connection).to receive(:post) { |_path, &blk| blk&.call(request); queue.shift }
    allow(connection).to receive(:get) { |_path, &blk| blk&.call(request); queue.shift }
    allow(Faraday).to receive(:new).and_return(connection)
    queue
  end

  def publish
    client.create_post(image_url: 'https://example.test/p.png', caption: 'hi')
  end

  before do
    allow(Rails.application.credentials).to receive(:dig).and_return('test')
    allow(client).to receive(:sleep) # no real backoff in the suite
  end

  it 'retries a publish Instagram reports as not-ready-yet, and succeeds' do
    stub_flow([ ok({ 'id' => 'container-1' }), ok({ 'status_code' => 'FINISHED' }),
                media_not_ready, ok({ 'id' => 'ig-post-1' }) ])

    expect(publish['id']).to eq('ig-post-1')
    expect(client).to have_received(:sleep).once
  end

  it 'gives up after the bounded number of attempts' do
    queue = stub_flow([ ok({ 'id' => 'container-1' }), ok({ 'status_code' => 'FINISHED' }) ] +
                      Array.new(described_class::PUBLISH_ATTEMPTS) { media_not_ready })

    expect { publish }.to raise_error(Instagram::Client::Error, /9007/)
    expect(queue).to be_empty
  end

  it 'does not retry an error that is not the not-ready signal' do
    queue = stub_flow([ ok({ 'id' => 'container-1' }), ok({ 'status_code' => 'FINISHED' }),
                        response(400, { 'error' => { 'code' => 100, 'message' => 'Invalid parameter' } }) ])

    expect { publish }.to raise_error(Instagram::Client::Error, /Invalid parameter/)
    expect(queue).to be_empty
    expect(client).not_to have_received(:sleep)
  end

  it 'publishes without retrying when Instagram is ready' do
    stub_flow([ ok({ 'id' => 'container-1' }), ok({ 'status_code' => 'FINISHED' }),
                ok({ 'id' => 'ig-post-2' }) ])

    expect(publish['id']).to eq('ig-post-2')
    expect(client).not_to have_received(:sleep)
  end
end
