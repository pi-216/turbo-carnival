@PRD-0006
Feature: Application Command
  As the Director
  I want a side effect to run only after its transaction commits
  So that the after-commit contract is implemented, not just described

  @DEV-0083 @wip
  Scenario: a side effect runs only after the transaction commits
    Given a command that schedules a side effect
    When it is called inside an open transaction
    Then the side effect runs only after the transaction commits
