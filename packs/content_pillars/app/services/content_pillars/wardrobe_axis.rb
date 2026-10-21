# frozen_string_literal: true

module ContentPillars
  # PRD 0007 A2 (#105): the wardrobe is a per-pillar axis the brain controls,
  # not a hardcoded SFW floor. This class is the "content config" home for that
  # axis (PRD 0005: "the adopted wardrobe ... is by then a value in the content
  # config"): it defines the SCALE of the axis and the CURRENT VALIDATED TIER
  # that bounds it.
  #
  # The scale is PRD 0005's wardrobe ladder (the miniskirt rungs L1-L5) with a
  # covered floor below and the swimwear extension above, so it "spans the
  # reveal range." Each rung is a COVERAGE STATEMENT (which regions are covered,
  # and how), not a mood word — PRD 0005's authoring rule. The floor rung is a
  # rung on the scale the brain can raise, NOT a global constraint: removing it
  # is what "no SFW-only default remains in the prompt path" means.
  #
  # PRD 0007 B2 (#109): each rung also declares whether it COVERS THE AREOLA IN
  # TEXT (covers_areola). That fact is the scene's own answer to B2's rule —
  # scenes that cover in text carry the areola terms in their own negative by
  # default (the belt-and-braces guard behind the 2026-10-18 checkpoint leak
  # finding); a rung that exposes the areola in text drops the terms and the
  # scene is free of the suppression. It is declared, never inferred from the
  # descriptor text, so a new rung cannot silently change a scene's negative.
  class WardrobeAxis
    # The areola terms a covering scene carries in its own negative. One
    # string, one home: the scene spec, the run variables and the graph token
    # all resolve to it.
    AREOLA_NEGATIVE = 'nipples, areola'

    Rung = Struct.new(:level, :descriptor, :covers_areola, keyword_init: true)

    LADDER = [
      Rung.new(level: 1, descriptor: 'wearing everyday clothing, torso and legs fully covered',
               covers_areola: true),
      Rung.new(level: 2, descriptor: 'wearing a knee-length skirt, torso fully covered',
               covers_areola: true),
      Rung.new(level: 3, descriptor: 'wearing an above-the-knee skirt, torso covered',
               covers_areola: true),
      Rung.new(level: 4, descriptor: 'wearing a mid-thigh skirt, torso covered',
               covers_areola: true),
      Rung.new(level: 5, descriptor: 'wearing a short miniskirt, hemline well above the knee, torso covered',
               covers_areola: true),
      Rung.new(level: 6, descriptor: 'wearing the shortest plausible skirt, hemline at the upper thigh, torso covered',
               covers_areola: true),
      Rung.new(level: 7, descriptor: 'wearing a one-piece swimsuit, areola and navel covered',
               covers_areola: true),
      Rung.new(level: 8, descriptor: 'wearing a two-piece bikini, minimal coverage, areola and navel covered',
               covers_areola: true)
    ].freeze

    # The miniskirt rung (PRD 0005 L4 — "the rung the founder's wording points
    # at"), named so the planner and the specs can target it by level.
    MINISKIRT_LEVEL = 5

    MIN_LEVEL = 1
    MAX_LEVEL = LADDER.size

    # The CURRENT VALIDATED TIER (A5 pre-flight, #107): the highest rung the
    # system will render on the primary venue. It is pushed up tier by tier as
    # the platform-tolerance read (B4) validates each rung, so it is the ceiling
    # on the axis. It defaults to the expected-pass anchor (the knee-length
    # rung) and is env-configurable so the pre-flight can raise it without a
    # deploy.
    VALIDATED_TIER_ENV = 'WARDROBE_VALIDATED_TIER'
    DEFAULT_VALIDATED_TIER = 2

    class << self
      # The current validated tier, clamped to the scale.
      def validated_tier
        tier = ENV.fetch(VALIDATED_TIER_ENV, DEFAULT_VALIDATED_TIER.to_s).to_i
        tier.clamp(MIN_LEVEL, MAX_LEVEL)
      end

      alias ceiling validated_tier

      # Is a rung on the scale (any level the DB may store)? Decoupled from the
      # dynamic tier so the data layer can hold every rung the brain has ever
      # set, even after the tier is lowered.
      def on_scale?(level)
        level.is_a?(Integer) && level.between?(MIN_LEVEL, MAX_LEVEL)
      end

      # The level actually in effect for a pillar: its target rung, but never
      # above the current validated tier. This single method is the source of
      # truth for BOTH the prompt and the audit record, so the render and the
      # recorded value always agree and are always bounded by the tier.
      def effective_level(pillar)
        target = pillar&.wardrobe_level || MIN_LEVEL
        [ target, validated_tier ].min.clamp(MIN_LEVEL, MAX_LEVEL)
      end

      # The coverage statement for a level (falls back to the floor if the
      # level is out of range, so a prompt is always well-formed).
      def descriptor_for(level)
        i = (level || MIN_LEVEL).to_i
        LADDER[(i - 1).clamp(0, LADDER.size - 1)].descriptor
      end

      def descriptor_for_pillar(pillar)
        descriptor_for(effective_level(pillar))
      end

      # PRD 0007 B2 (#109): the scene negative for a rung — the areola terms
      # when the rung covers the areola in text, otherwise nothing. This is the
      # production rail's half of "each scene definition owns its own
      # negative": the run records it and the graph's {{negative_prompt}} token
      # (node 79) resolves it. An unknown level is not declared to cover, so it
      # carries no suppression — the default is freedom, and a covering scene
      # must say so.
      def negative_for(level)
        rung = LADDER.find { |r| r.level == level.to_i }
        rung && rung.covers_areola ? AREOLA_NEGATIVE : ''
      end
    end
  end
end
