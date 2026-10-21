@PRD-0007
Feature: Realism Advisory
  As the growth harness
  I want the realism scores to measure rather than veto
  So that a below-default render is ranked last, not thrown away

  # PRD 0007 B3 (#110). Realism was the LAST veto in the render stack: it now
  # MEASURES (aesthetic + Laplacian sharpness) and the selection layer ORDERS the
  # pool by the same defaults -- below-default is low priority, never purged.
  @DEV-0110
  Scenario: a below-default render is measured, not rejected
    Given a rendered image whose aesthetic score is 3.2 and sharpness is 12.4
    When the realism measurement runs
    Then the result is measured and flagged
    And the result offers no veto for a caller to act on

  @DEV-0110
  Scenario: a below-default asset is ranked last, not purged
    Given a library holding a below-default asset and a sharp asset
    When the available photos are listed
    Then both assets are listed
    And the below-default asset is last
