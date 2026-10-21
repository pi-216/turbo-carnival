@PRD-0006
Feature: Parity Audit
  As the Director
  I want a parity audit run to mark every template rail
  So that a parity claim has a run behind it

  Background:
    Given the parity audit script is run against the repo

  @DEV-0090
  Scenario: a parity audit run prints one line per rail
    When it completes
    Then it prints one line per template rail: CONFORM, GAP, or DEVIATION(reason)
    And no template rail is in GAP

  @DEV-0090
  Scenario: deleting the head meta takes the Turbo rail to GAP
    When the turbo refresh meta is deleted from the layout head, the audit is re-run
    Then the audit reports the Turbo rail in GAP
    And the audit exits non-zero
