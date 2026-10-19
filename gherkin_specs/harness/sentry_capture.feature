@PRD-0006
Feature: Sentry Capture
  As the Director
  I want exceptions in a configured environment to reach Sentry
  So that failures are observable rather than silent

  @DEV-0083
  Scenario: an exception in a configured environment is captured
    Given a DSN is present in encrypted credentials
    And the application runs in a configured environment
    When an exception is raised
    Then an event is captured
