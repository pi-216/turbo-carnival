# frozen_string_literal: true

require 'rails_helper'

# The engagement feedback path had TWO defects at once, and both are asserted here
# because either one alone leaves the columns empty:
#   1. nothing invoked CollectPostInsights (no rake task, no cron), so the newest
#      insights write was 2026-05-27 while 107 posted items had none at all;
#   2. its selection had no ORDER BY, so even a manual run re-refreshed the same 25
#      OLDEST rows and never reached the posts with no insights.
# Growth::WeeklyReview aggregates engagement_rate per pillar to steer hashtags and
# content direction, so both defects zeroed the strategy layer's only content signal
# -- silently, with no error, no log line and no overdue row.
RSpec.describe 'scheduling:collect_insights' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona, name: 'Sarah') }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def posted(at:, insights_at: nil)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'posted', posted_at: at,
                             provider_post_id: "ig-#{SecureRandom.hex(6)}",
                             insights_updated_at: insights_at)
  end

  def stub_insights_api(status: 200, body: nil)
    body ||= { 'data' => [{ 'name' => 'likes', 'values' => [{ 'value' => 7 }] },
                          { 'name' => 'comments', 'values' => [{ 'value' => 1 }] },
                          { 'name' => 'reach', 'values' => [{ 'value' => 100 }] },
                          { 'name' => 'saved', 'values' => [{ 'value' => 2 }] },
                          { 'name' => 'shares', 'values' => [{ 'value' => 1 }] }] }
    connection = double('faraday')
    allow(connection).to receive(:get).and_return(double('response', status: status, body: body))
    allow(Faraday).to receive(:new).and_return(connection)
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig)
      .with(:instagram, :access_token).and_return('test-token')
  end

  def run_task
    Rake::Task['scheduling:collect_insights'].reenable
    Rake::Task['scheduling:collect_insights'].invoke
  end

  it 'spends its 25-row budget on never-collected posts, newest first' do
    stale = Array.new(3) { posted(at: 3.days.ago, insights_at: 10.hours.ago) }
    never = Array.new(30) { |i| posted(at: (30 + i).days.ago) } # first == newest
    stub_insights_api

    run_task

    # Already-collected rows keep their timestamp: with no ORDER BY these oldest
    # rows were the ones re-refreshed on every run, which is exactly how the newest
    # write stayed at 2026-05-27 while everything since stayed NULL.
    stale.each do |p|
      expect(p.reload.insights_updated_at).to be_within(5.seconds).of(10.hours.ago)
    end

    # The newest never-collected post is collected, with the API's numbers parsed
    # into the columns the growth review reads.
    newest = never.first.reload
    expect(newest.insights_updated_at).to be_present
    expect(newest.reach).to eq(100)
    expect(newest.likes_count).to eq(7)
    expect(newest.comments_count).to eq(1)
    expect(newest.saved_count).to eq(3) # saved + shares
    expect(newest.engagement_rate).to eq(11.0) # (7 + 1 + 3) / 100 * 100

    # The budget is finite (Instagram rate limit): the oldest never-collected rows
    # wait for the next run rather than being silently skipped forever.
    expect(never.last.reload.insights_updated_at).to be_nil
  end

  it 'loads the rake tasks exactly once (a second load duplicates every task body)' do
    # Rails.application.load_tasks APPENDS an action to an already-defined task, so
    # a second load in the same process makes every rake task run its body twice --
    # which is how this suite briefly made scheduling:post_scheduled publish two
    # posts per invoke and broke the release-pacing spec. See spec/support/rake_tasks.rb.
    expect(Rake::Task['scheduling:post_scheduled'].actions.size).to eq(1)
    expect(Rake::Task['scheduling:collect_insights'].actions.size).to eq(1)
  end

  it 'exits non-zero when candidates exist but the API returns nothing' do
    posted(at: 3.days.ago)
    stub_insights_api(status: 500)

    # A silent no-op is the failure mode this task exists to end: the publisher
    # logs a WARN and publishes anyway, and the ops board's insights-stale check
    # catches a sustained failure.
    expect { run_task }.to raise_error(SystemExit)
  end

  it 'names a deleted media (400/code 100) as permanently unavailable instead of skipping it silently' do
    gone = posted(at: 3.days.ago)
    stub_insights_api(status: 400,
                      body: { 'error' => { 'message' => '(#100) Tried accessing nonexisting field (insights)',
                                           'code' => 100 } })

    # Measured in production 2026-09-20: 11 posts answer 400/code 100 forever
    # (media deleted / inaccessible) and, because the query orders never-collected
    # rows first, they re-entered every run. Before this the non-200 returned nil
    # with no log line at all, so the publisher printed "refreshed 14 of 25" and
    # the 11 unexplained failures were indistinguishable from a transient blip.
    expect(Rails.logger).to receive(:warn).with(/media returned HTTP 400/).at_least(:once)
    expect(Rails.logger).to receive(:warn).with(/can never be refreshed/).at_least(:once)

    expect { run_task }.not_to raise_error

    expect(gone.reload.insights_updated_at).to be_nil
    # ...and the verdict is RECORDED, which is what stops the row re-entering the
    # selection on the next run (11 of the 25 slots, every run, forever before).
    expect(gone.reload.insights_unavailable_at).to be_present
  end

  # The budget is 25 rows/run against a 200-call/hour API limit, so a row that can
  # never be refreshed must not keep spending slots: measured 2026-09-22, 11 such
  # rows took 11 slots on every run while only 14 remained for real work.
  it 'does not re-select a post the API has already called terminal' do
    gone = posted(at: 3.days.ago)
    gone.update_columns(insights_unavailable_at: 1.hour.ago)
    live = posted(at: 2.days.ago)
    stub_insights_api

    run_task

    # The dead row was not asked about again, and its slot went to real work.
    expect(gone.reload.insights_updated_at).to be_nil
    expect(live.reload.reach).to eq(100)
  end

  # Not a tombstone: code 100 also covers a media THIS token cannot read, so a
  # permission/token change must be able to recover a row. After the retry window
  # the row is asked about again rather than being dead forever.
  it 're-probes a terminal post once the retry window has passed' do
    old = posted(at: 40.days.ago)
    old.update_columns(insights_unavailable_at: 31.days.ago)
    stub_insights_api

    run_task

    expect(old.reload.insights_updated_at).to be_present
  end

  # The denominator of the growth review's per-pillar engagement. A default here
  # is not a convenience: it fabricates the number the pre-registered 3%
  # GO/PIVOT/KILL criterion is read from.
  it 'records a missing `reach` metric as unknown (nil), never as a default' do
    post = posted(at: 3.days.ago)
    stub_insights_api(body: { 'data' => [{ 'name' => 'likes', 'values' => [{ 'value' => 2 }] },
                                        { 'name' => 'comments', 'values' => [{ 'value' => 0 }] }] })

    expect(Rails.logger).to receive(:warn).with(/no `reach` metric/).at_least(:once)

    expect { run_task }.not_to raise_error

    post.reload
    expect(post.insights_updated_at).to be_present
    expect(post.reach).to be_nil          # UNKNOWN, not 1
    expect(post.likes_count).to eq(2)
    expect(post.engagement_rate).to eq(0.0) # no denominator => no rate, not a fabricated one
  end
end
