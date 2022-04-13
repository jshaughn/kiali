Feature: Kiali Graph page - Display menu

  User opens the Graph page and manipulates the "error-rates" demo

  Background:
    Given user is at administrator perspective

#  @graph-page-display
#  Scenario: Graph no namespaces
#    When user graphs "" namespaces
#    Then user sees no namespace selected
#
#  @graph-page-display
#  Scenario: Graph alpha and beta namespaces
#    When user graphs "alpha,beta" namespaces
#    Then user sees the "alpha" namespace
#    And user sees the "beta" namespace

  @graph-page-display
  Scenario: Graph alpha namespace
    When user graphs "alpha" namespaces
    Then user sees the "alpha" namespace

  @graph-page-display
  Scenario: Response-time edge labels
    When user enables "responseTime" edge labels
    Then user sees "responseTime" edge labels
