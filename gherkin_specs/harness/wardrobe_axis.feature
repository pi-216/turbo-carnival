@PRD-0007
Feature: Wardrobe Axis
  As the growth planner
  I want to set each pillar's wardrobe intensity
  So that the reveal is a decision, not a hardcoded SFW floor

  @DEV-0105
  Scenario: a pillar renders at its set wardrobe rung
    Given a content pillar at wardrobe level 5
    And the wardrobe tier is at the top rung
    When a render prompt is built
    Then the prompt reads a short miniskirt

  @DEV-0105
  Scenario: no SFW-only default remains
    Given a content pillar
    When a render prompt is built
    Then the prompt reads fully covered clothing
    And no SFW-only clothing default remains

  # PRD 0007 B2 (#109): the scene's own negative. A scene that covers the
  # areola in text carries the terms in its own negative (the guard behind the
  # 2026-10-18 checkpoint leak finding); a scene that exposes it in text is
  # free of the suppression.
  @DEV-0109
  Scenario: a covering scene carries the areola terms in its own negative
    Given a content pillar at wardrobe level 5
    When the scene negative is resolved for the pillar
    Then the scene negative reads "nipples, areola"

  @DEV-0109
  Scenario: a scene that exposes the areola in text carries no suppression
    Given a wardrobe rung that exposes the areola in text
    When the scene negative is resolved for rung 9
    Then the scene negative carries no areola terms
