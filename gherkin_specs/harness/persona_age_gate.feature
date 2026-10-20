@PRD-0007
Feature: Persona Age Gate
  As the publisher
  I want a queued post's render checked against the age floor before it is public
  So that a render that reads as a minor is held and every decided read is recorded on the row

  @DEV-0108
  Scenario: a band that spans 18 publishes at the SFW tier and is recorded
    Given a queued SFW-tier post whose age read is "17-19"
    When the persona age gate runs with writes enabled
    Then the post keeps its slot
    And the read is recorded on the row with band "17-19" and tier "sfw"

  @DEV-0108
  Scenario: a band that spans 18 is held at the explicit tier
    Given a queued explicit-tier post whose age read is "17-19"
    When the persona age gate runs with writes enabled
    Then the post is held with both publisher clocks cleared
    And a growth decision records the hold

  @DEV-0108
  Scenario: a read that looks like a minor is held at the SFW tier
    Given a queued SFW-tier post whose age read is "a young girl, likely a teenager"
    When the persona age gate runs with writes enabled
    Then the post is held with both publisher clocks cleared
