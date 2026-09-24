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

  # Records the params of every POST the client makes, in order. The shared
  # request object used by stub_flow only ever holds the LAST one, and the
  # container-create request is not the last.
  def stub_recording(post_responses)
    recorded = []
    queue = post_responses.dup
    connection = double('faraday')
    allow(connection).to receive(:post) do |_path, &blk|
      req = Struct.new(:params).new({})
      blk&.call(req)
      recorded << req.params
      queue.shift
    end
    allow(connection).to receive(:get) do |_path, &blk|
      blk&.call(Struct.new(:params).new({}))
      ok({ 'status_code' => 'FINISHED' })
    end
    allow(Faraday).to receive(:new).and_return(connection)
    recorded
  end

  # AI Self-Disclosure: the container create must ASK for the platform's AI
  # label, not rely on the platform inferring it from the IPTC marker in the
  # bytes. `add-synthetic-provenance` requires viewer-facing disclosure "via the
  # platform's own label where the platform applies one" and left task 4.1 (the
  # surface half) open; this is that half.
  describe 'AI self-disclosure on the media container' do
    it 'sets the disclosure on the container create and still publishes' do
      recorded = stub_recording([ ok({ 'id' => 'container-1' }), ok({ 'id' => 'ig-post-1' }) ])

      expect(publish['id']).to eq('ig-post-1')
      container = recorded.first
      expect(container[described_class::AI_DISCLOSURE_PARAM]).to eq('true')
      expect(container['image_url']).to eq('https://example.test/p.png')
      expect(container['caption']).to eq('hi')
    end

    it 'falls back to an unflagged container when the API rejects the parameter' do
      recorded = stub_recording([ response(400, { 'error' => { 'code' => 100,
                                                              'message' => 'Invalid parameter' } }),
                                  ok({ 'id' => 'container-1' }), ok({ 'id' => 'ig-post-1' }) ])

      expect(publish['id']).to eq('ig-post-1')
      expect(recorded.first).to have_key(described_class::AI_DISCLOSURE_PARAM)
      expect(recorded[1]).not_to have_key(described_class::AI_DISCLOSURE_PARAM)
      expect(recorded[1]['image_url']).to eq('https://example.test/p.png')
    end

    it 'still raises when the fallback container create also fails' do
      stub_recording([ response(400, { 'error' => { 'code' => 100, 'message' => 'Invalid parameter' } }),
                       response(500, { 'error' => { 'message' => 'boom' } }) ])

      expect { publish }.to raise_error(Instagram::Client::Error, /boom/)
    end
  end

  # Reach ATTRIBUTION (added 2026-09-24): the account's own insights say whether
  # any reach came from accounts that do not follow it. That number is what
  # decides "content problem" vs "no distribution at all", and it cannot be
  # derived from per-post reach sums.
  describe '#reach_attribution' do
    def reach_body(results, total: 6, with_breakdown: true)
      tv = { 'value' => total }
      tv['breakdowns'] = [ { 'dimension_keys' => [ 'follow_type' ], 'results' => results } ] if with_breakdown
      ok({ 'data' => [ { 'name' => 'reach', 'period' => 'day', 'total_value' => tv } ] })
    end

    def profile_views_body(value)
      ok({ 'data' => [ { 'name' => 'profile_views', 'period' => 'day',
                         'total_value' => { 'value' => value } } ] })
    end

    before { allow(client).to receive(:sleep) }

    it 'reads a follow_type breakdown, treating an OMITTED dimension as a measured zero' do
      stub_flow([ reach_body([ { 'dimension_values' => [ 'FOLLOWER' ], 'value' => 6 } ]),
                  profile_views_body(0) ])

      att = client.reach_attribution
      expect(att[:follower_reach]).to eq(6)
      expect(att[:non_follower_reach]).to eq(0)
      expect(att[:reach_total]).to eq(6)
      expect(att[:profile_views]).to eq(0)
    end

    it 'reports a non-zero non-follower reach as discovery' do
      stub_flow([ reach_body([ { 'dimension_values' => [ 'FOLLOWER' ], 'value' => 3 },
                               { 'dimension_values' => [ 'NON_FOLLOWER' ], 'value' => 9 } ], total: 12),
                  profile_views_body(4) ])

      att = client.reach_attribution
      expect(att[:follower_reach]).to eq(3)
      expect(att[:non_follower_reach]).to eq(9)
      expect(att[:profile_views]).to eq(4)
    end

    it 'leaves the parts UNKNOWN (nil) when the response carries no breakdown block' do
      stub_flow([ reach_body([], with_breakdown: false), profile_views_body(0) ])

      att = client.reach_attribution
      expect(att[:non_follower_reach]).to be_nil
      expect(att[:follower_reach]).to be_nil
      expect(att[:reach_total]).to eq(6)
    end

    it 'returns nils instead of raising when the insights call fails' do
      stub_flow([ response(400, { 'error' => { 'code' => 100, 'message' => 'Invalid parameter' } }),
                  response(400, { 'error' => { 'code' => 100, 'message' => 'Invalid parameter' } }) ])

      att = client.reach_attribution
      expect(att).to eq(follower_reach: nil, non_follower_reach: nil, reach_total: nil, profile_views: nil)
    end
  end
end
