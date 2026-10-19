@PRD-0006
Feature: Turbo Morph Refresh
  As the Director
  I want the layout HEAD to carry the Turbo morph refresh trigger
  So that Turbo morphing stays live and the gate asserts the mechanism, not the artifact

  @DEV-0083
  Scenario: the layout HEAD declares the morph refresh method
    When I open the application layout
    Then the layout HEAD carries the turbo morph refresh method
