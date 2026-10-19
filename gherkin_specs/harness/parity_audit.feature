@PRD-0006
Feature: Parity Audit
  As the Director
  I want a parity audit run to mark every template rail
  So that a parity claim has a run behind it

  @DEV-0083 @wip
  Scenario: a parity audit run prints one line per rail
    Given the parity audit script is run against the repo
    When it completes
    Then it prints one line per template rail: CONFORM, GAP, or DEVIATION(reason)
