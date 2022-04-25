Feature: Kiali Graph page - Display menu

  User opens the Graph page and manipulates the "error-rates" demo

  Background:
    Given user is at administrator perspective

#  @graph-page-display
#  Scenario: Graph no namespaces
#    When user graphs "" namespaces
#    Then user sees no namespace selected

@graph-page-display
Scenario: Graph alpha and beta namespaces
  When user graphs "alpha,beta" namespaces
  Then user sees the "alpha" namespace
  And user sees the "beta" namespace

@graph-page-display
Scenario: User clicks Display Menu
  When user opens display menu
  Then the display menu opens
  And the display menu has default settings
  And the graph reflects default settings


#######

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

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Request Throughput edge labels
  When user enables "throughputRequest" "throughput" edge labels
  Then user sees "throughput" edge labels

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Response Throughput edge labels
  When user enables "throughputResponse" "throughput" edge labels
  Then user sees "throughput" edge labels

# edge label variable must match edge data name
@graph-page-display
Scenario: Uncheck throughput edge labels
  When user disables "throughput" edge labels
  Then user sees "throughput" edge label option is closed

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Traffic Distribution edge labels
  When user enables "trafficDistribution" edge labels
  Then user sees "httpPercentReq" edge labels

# edge label variable must match edge data name
@graph-page-display
Scenario: Uncheck Traffic Distribution edge labels
  When user disables "trafficDistribution" edge labels
  Then user sees "trafficDistribution" edge label option is closed

# percentile variable must match input id
# edge label variable must match edge data name
@graph-page-display
Scenario: Traffic Rate edge labels
  When user enables "trafficRate" edge labels
  Then user sees "http" edge labels

# edge label variable must match edge data name
@graph-page-display
Scenario: Uncheck Traffic Distribution edge labels
  When user disables "trafficRate" edge labels
  Then user sees "trafficRate" edge label option is closed
