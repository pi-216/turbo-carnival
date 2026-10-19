# frozen_string_literal: true

require 'rails_helper'

# The pre-publish near-duplicate gate: an image already published (or already
# queued to publish) must not go out again. These examples pin the decision rule
# that keeps exactly one member of a collapsed render batch (earliest slot wins),
# the hold write (both publisher clocks cleared, metadata recorded, Decision
# row), the FAIL-OPEN direction on an unreadable render, the idempotency that
# stops an hourly caller re-deciding the same post, and the hash cache's
# invalidation.
RSpec.describe Growth::NearDuplicateGate do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let!(:goal) { create(:growth_goal, persona: persona) }
  let(:root) { Dir.mktmpdir('near-dup-spec') }

  # Injected hashes. The gate never decodes anything itself in these examples --
  # bin/dhash.py is exercised separately -- so a basename keys a 64-bit value.
  # A basename with no entry is "unreadable", which is how the fail-open branch
  # is reached.
  let(:dup_a) { 0x0000_0000_0000_0000 }
  let(:dup_b) { 0x0000_0000_0000_0007 } # distance 3 from dup_a: inside the threshold
  let(:far)   { 0xffff_ffff_ffff_ffff } # distance 64 from dup_a: nothing like it

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def hash_source(map)
    lambda do |paths|
      paths.each_with_object({}) do |path, acc|
        bits = map[File.basename(path)]
        acc[path] = bits unless bits.nil?
      end
    end
  end

  def photo(name)
    path = File.join(root, name)
    File.binwrite(path, "not-a-real-image-#{name}")
    ContentPillars::Photo.create!(persona: persona, path: path, content_pillar: pillar)
  end

  def queued(name, slot: 2.days.from_now, status: 'scheduled')
    Scheduling::Post.create!(persona: persona, photo: photo(name), caption: 'caption',
                             status: status, scheduled_at: slot, optimal_time_calculated: slot)
  end

  def published(name, slot: 1.day.ago)
    Scheduling::Post.create!(persona: persona, photo: photo(name), caption: 'caption',
                             status: 'posted', provider_post_id: "ig-#{name}", posted_at: slot,
                             scheduled_at: slot, optimal_time_calculated: slot)
  end

  def run(source_map, dry_run: false, **opts)
    described_class.call(persona: persona, dry_run: dry_run, cache: false,
                         hash_source: hash_source(source_map), **opts)
  end

  it 'holds a queued post whose render duplicates an already-published one' do
    twin = published('twin.png', slot: 3.days.ago)
    post = queued('candidate.png', slot: 2.days.from_now)

    results = run({ 'twin.png' => dup_a, 'candidate.png' => dup_b })

    expect(results.size).to eq(1)
    expect(results.first.verdict).to eq(:duplicate)
    expect(results.first.outcome).to eq(:held)
    expect(results.first.distance).to eq(3)
    expect(results.first.partner_kind).to eq(:published)
    expect(results.first.partner_post_id).to eq(twin.id)

    post.reload
    expect(post.scheduled_at).to be_nil
    expect(post.optimal_time_calculated).to be_nil
    expect(post.status).to eq('scheduled') # the hold is the clocks, not the state machine
    expect(post.caption_metadata['near_dup_gate']['held']).to be(true)
    expect(post.caption_metadata['near_dup_gate']['partner_post_id']).to eq(twin.id)

    decision = Growth::Decision.where(action: 'near_dup_hold').order(:id).last
    expect(decision).not_to be_nil
    expect(decision.reason).to include("held post #{post.id}")
    expect(decision.reason).to include('published post')
  end

  it 'keeps the EARLIEST of two queued twins and holds the later one' do
    early = queued('early.png', slot: 1.day.from_now)
    late  = queued('late.png', slot: 2.days.from_now)

    results = run({ 'early.png' => dup_a, 'late.png' => dup_a })

    by_post = results.index_by(&:post_id)
    expect(by_post[early.id].verdict).to eq(:kept_earliest)
    expect(by_post[early.id].outcome).to eq(:kept)
    expect(by_post[late.id].verdict).to eq(:duplicate)
    expect(by_post[late.id].outcome).to eq(:held)
    expect(by_post[late.id].partner_post_id).to eq(early.id)

    expect(early.reload.scheduled_at).not_to be_nil
    expect(late.reload.scheduled_at).to be_nil
    # Exactly one of the pair survives: that is the whole point of the queue leg.
    expect([ early.reload.scheduled_at, late.reload.scheduled_at ].compact.size).to eq(1)
  end

  it 'leaves a distinct render alone and records the read' do
    published('other.png', slot: 3.days.ago)
    post = queued('candidate.png', slot: 2.days.from_now)

    results = run({ 'other.png' => dup_a, 'candidate.png' => far })

    expect(results.first.verdict).to eq(:distinct)
    expect(results.first.outcome).to eq(:cleared)
    expect(results.first.distance).to eq(64)
    expect(post.reload.scheduled_at).not_to be_nil
    expect(post.caption_metadata['near_dup_gate']['verdict']).to eq('distinct')
    expect(Growth::Decision.where(action: 'near_dup_hold')).to be_empty
  end

  it 'FAILS OPEN on an unreadable render: records nothing and publishes as before' do
    post = queued('candidate.png', slot: 2.days.from_now)

    results = run({}) # the hash source knows nothing -> no hash for the asset

    expect(results).to be_empty
    post.reload
    expect(post.scheduled_at).not_to be_nil
    expect(post.caption_metadata).to be_blank
  end

  it 'does not re-read a post that already carries a verdict' do
    post = queued('candidate.png', slot: 2.days.from_now)
    run({ 'candidate.png' => far })

    calls = []
    source = lambda do |paths|
      calls.concat(paths)
      paths.to_h { |p| [ p, far ] }
    end
    results = described_class.call(persona: persona, dry_run: false, cache: false, hash_source: source)

    expect(results).to be_empty
    expect(calls).not_to include(File.join(root, 'candidate.png'))
    expect(post.reload.caption_metadata['near_dup_gate']['verdict']).to eq('distinct')
  end

  it 're-decides a cleared render when the published corpus has grown meanwhile' do
    post = queued('candidate.png', slot: 2.days.from_now)
    run({ 'candidate.png' => far }) # cleared against an EMPTY corpus

    published('twin.png', slot: 1.hour.ago) # a new published image, same render
    results = run({ 'candidate.png' => dup_a, 'twin.png' => dup_a })

    expect(results.first.verdict).to eq(:duplicate)
    expect(post.reload.scheduled_at).to be_nil
  end

  it 'drops a held duplicate out of the queue counters (cadence shortfall reopens)' do
    published('twin.png', slot: 3.days.ago)
    queued('candidate.png', slot: 2.days.from_now)

    due = lambda do
      Scheduling::Post.where(persona: persona, status: %w[draft scheduled])
                      .where('scheduled_at > ? OR optimal_time_calculated > ?', Time.current, Time.current)
                      .count
    end
    expect(due.call).to eq(1)

    run({ 'twin.png' => dup_a, 'candidate.png' => dup_a })

    expect(due.call).to eq(0)
  end

  it 'merges caption_metadata instead of replacing it (the age gate read survives)' do
    published('twin.png', slot: 3.days.ago)
    post = queued('candidate.png', slot: 2.days.from_now)
    post.update_columns(caption_metadata: { 'age_gate' => { 'verdict' => 'adult' } })

    run({ 'twin.png' => dup_a, 'candidate.png' => dup_a })

    meta = post.reload.caption_metadata
    expect(meta['age_gate']).to eq({ 'verdict' => 'adult' })
    expect(meta['near_dup_gate']['verdict']).to eq('duplicate')
  end

  it 'reports would_hold and writes nothing on a dry run' do
    published('twin.png', slot: 3.days.ago)
    post = queued('candidate.png', slot: 2.days.from_now)

    results = run({ 'twin.png' => dup_a, 'candidate.png' => dup_a }, dry_run: true)

    expect(results.first.outcome).to eq(:would_hold)
    expect(post.reload.scheduled_at).not_to be_nil
    expect(post.caption_metadata).to be_blank
    expect(Growth::Decision.where(action: 'near_dup_hold')).to be_empty
  end

  it 'honours a threshold override' do
    published('twin.png', slot: 3.days.ago)
    post = queued('candidate.png', slot: 2.days.from_now)

    results = run({ 'twin.png' => dup_a, 'candidate.png' => dup_b }, threshold: 2)

    expect(results.first.verdict).to eq(:distinct)
    expect(post.reload.scheduled_at).not_to be_nil
  end

  describe 'Hasher (the real bin/dhash.py, not a stub)' do
    # The seam the examples above stub: Ruby -> the Python CLI -> 64-bit hashes.
    # Skipped, not failed, when the ComfyUI venv is absent -- the gate fails OPEN
    # in that case, so an absent python is a documented degraded state rather
    # than a broken gate.
    let(:python) { described_class::Hasher.python }

    before { skip "no pythons at #{python}" unless File.executable?(python) }

    def make_image(name, invert: false)
      path = File.join(root, name)
      script = <<~PY
        import sys
        from PIL import Image
        w = h = 96
        px = [(x * 255 // w, y * 255 // h, (x + y) * 255 // (w + h)) for y in range(h) for x in range(w)]
        if #{invert ? 'True' : 'False'}:
            px = [(255 - r, 255 - g, 255 - b) for (r, g, b) in px]
        im = Image.new("RGB", (w, h))
        im.putdata(px)
        im.save(sys.argv[1])
      PY
      out, err, status = Open3.capture3(python, '-c', script, path)
      raise "image gen failed: #{err}" unless status.success?

      path
    end

    it 'gives a re-saved image the same hash and a different image a distant one' do
      base = make_image('base.png')
      same = make_image('same.png')
      other = make_image('other.png', invert: true)

      hashes = described_class::Hasher.call([ base, same, other ])

      expect(hashes.keys).to contain_exactly(base, same, other)
      expect(hashes[base]).to eq(hashes[same])
      distance = described_class.new(persona: persona).send(:hamming, hashes[base], hashes[other])
      expect(distance).to be > described_class::DEFAULT_THRESHOLD
    end

    it 'reports an undecodable file as an error without aborting the batch' do
      good = make_image('good.png')
      bad = File.join(root, 'not-an-image.png')
      File.write(bad, 'this is not a PNG')

      hashes = described_class::Hasher.call([ good, bad ])

      expect(hashes.keys).to eq([ good ]) # the bad path is simply absent: fail open
    end
  end

  describe 'hash cache' do
    let(:cache_path) { File.join(root, 'cache.json') }

    def cached_run(map, paths_seen)
      source = lambda do |paths|
        paths_seen.concat(paths)
        paths.each_with_object({}) { |p, acc| acc[p] = map[File.basename(p)] }
      end
      described_class.call(persona: persona, dry_run: true, cache: true, cache_path: cache_path,
                           hash_source: source)
    end

    it 'hashes the corpus once, reuses it, and invalidates on a changed asset' do
      published('twin.png', slot: 3.days.ago)
      queued('candidate.png', slot: 2.days.from_now)
      map = { 'twin.png' => dup_a, 'candidate.png' => far }

      first = []
      cached_run(map, first)
      expect(first.size).to eq(2)
      expect(File.file?(cache_path)).to be(true)

      second = []
      cached_run(map, second)
      expect(second).to be_empty # nothing re-hashed: the cache was authoritative

      # An in-place rewrite (the publisher's PhotoAssetMarker does exactly this)
      # changes size+mtime, so the entry is recomputed rather than trusted.
      File.binwrite(File.join(root, 'twin.png'), 'rewritten-with-a-marker')
      third = []
      cached_run(map, third)
      expect(third).to include(File.join(root, 'twin.png'))
    end
  end
end
