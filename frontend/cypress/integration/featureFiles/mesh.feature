@mesh-page
# don't change first line of this file - the tag is used for the test scripts to identify the test suite

Feature: Kiali Mesh page

  User opens the Mesh page with bookinfo deployed

  Background:
    Given user is at administrator perspective
    And user is at the "mesh" page

# NOTE: Mesh Find/Hide has its own feature file

  @selected
  Scenario: Open mesh Tour
    When user opens mesh tour
    Then user "sees" mesh tour

  Scenario: Close mesh Tour
    When user closes mesh tour
    Then user "does not see" mesh tour

  @selected
  Scenario: See mesh
    Then mesh side panel is shown
    And user sees expected mesh infra

  # @bookinfo-app
  # Scenario: See DataPlane