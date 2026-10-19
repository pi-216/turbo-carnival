# frozen_string_literal: true

require 'rails_helper'

# Slot allocation replaced "scheduled_at = Time.current + N days", which stamped
# every post produced in a tick with the same wall-clock time: the hourly
# publisher then released them together (measured 2026-09-19: three posts inside
# 24 s) and days could exceed the cadence cap (2026-09-20 carried 6 against a
# 3/day cap). These examples pin the two properties that prevent a recurrence:
# no two slots inside SLOT_GAP_MINUTES, and no day above posts_per_day.
RSpec.describe Growth::PostSlotPlanner do
  subject(:planner) { described_class }

  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def schedule_at(time)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'x', status: 'scheduled',
                             scheduled_at: time, optimal_time_calculated: time)
  end

  describe '.next_slot' do
    it 'places the first post on the next day inside the posting window' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      slot = planner.next_slot(persona: persona, posts_per_day: 3, now: now)

      expect(slot.to_date).to eq(Date.new(2026, 9, 20))
      expect(slot.hour).to eq(described_class::WINDOWS.first.first)
      expect(slot).to be > now
    end

    it 'never returns a slot on the current day, even with a zero lead' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      slot = planner.next_slot(persona: persona, posts_per_day: 3, min_lead_days: 0, now: now)

      expect(slot.to_date).to eq(Date.new(2026, 9, 20))
    end

    it 'keeps successive allocations at least SLOT_GAP_MINUTES apart' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      slots = 3.times.map do
        slot = planner.next_slot(persona: persona, posts_per_day: 3, now: now)
        schedule_at(slot)
        slot
      end

      gaps = slots.each_cons(2).map { |a, b| (b - a) / 60.0 }
      expect(gaps).to all(be >= described_class::SLOT_GAP_MINUTES)
      expect(slots.map(&:to_date).uniq.size).to eq(1)
    end

    it 'never allocates inside the gap of a post already on the day' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      schedule_at(Time.zone.local(2026, 9, 20, 9, 30))

      slot = planner.next_slot(persona: persona, posts_per_day: 3, now: now)

      expect(slot.to_date).to eq(Date.new(2026, 9, 20))
      expect((slot - Time.zone.local(2026, 9, 20, 9, 30)).abs / 60.0)
        .to be >= described_class::SLOT_GAP_MINUTES
    end

    it 'moves to the next day once the day holds posts_per_day posts' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      %w[09:00 10:30 14:00].each { |t| schedule_at(Time.zone.local(2026, 9, 20, *t.split(':').map(&:to_i))) }

      slot = planner.next_slot(persona: persona, posts_per_day: 3, now: now)

      expect(slot.to_date).to eq(Date.new(2026, 9, 21))
    end

    it 'ignores posts of other personas' do
      now = Time.zone.local(2026, 9, 19, 12, 0)
      other = create(:persona)
      other_photo = ContentPillars::Photo.create!(persona: other, path: 'spec-other.png',
                                                  content_pillar: pillar)
      Scheduling::Post.create!(persona: other, photo: other_photo, caption: 'x', status: 'scheduled',
                               scheduled_at: Time.zone.local(2026, 9, 20, 9, 0))

      slot = planner.next_slot(persona: persona, posts_per_day: 3, now: now)

      expect(slot).to eq(Time.zone.local(2026, 9, 20, 9, 0))
    end
  end
end
