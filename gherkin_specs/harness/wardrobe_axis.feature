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
