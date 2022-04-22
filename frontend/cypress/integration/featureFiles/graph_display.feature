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
Scenario: User clicks Display Menu
  When user opens display menu
  Then the display menu opens

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Average Response-time edge labels
  When user enables "avg" "responseTime" edge labels
  Then user sees "responseTime" edge labels

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Median Response-time edge labels
    When user enables "rt50" "responseTime" edge labels
    Then user sees "responseTime" edge labels

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: 95th Percentile Response-time edge labels
  When user enables "rt95" "responseTime" edge labels
  Then user sees "responseTime" edge labels

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: 99th Percentile Response-time edge labels
  When user enables "rt99" "responseTime" edge labels
  Then user sees "responseTime" edge labels

# edge label variable must match edge data name
@graph-page-display
Scenario: Uncheck response time edge labels
  When user disables "responseTime" edge labels
  Then user sees "responseTime" edge label option is closed
