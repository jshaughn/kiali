import { Before, Given, Then, When } from 'cypress-cucumber-preprocessor/steps';

const url = '/console';

Before(() => {
  // Copied from overview.ts.  This prevents cypress from stopping on errors unrelated to the tests.
  // There can be random failures due timeouts/loadtime/framework that throw browser errors.  This
  // prevents a CI failure due something like a "slow".  There may be a better way to handle this.
  cy.on('uncaught:exception', (err, runnable, promise) => {
    // when the exception originated from an unhandled promise
    // rejection, the promise is provided as a third argument
    // you can turn off failing the test in this case
    if (promise) {
      return false;
    }
    // we still want to ensure there are no other unexpected
    // errors, so we let them fail the test
  });
});

When('user graphs {string} namespaces', namespaces => {
  // Forcing "Pause" to not cause unhandled promises from the browser when cypress is testing
  cy.visit(url + `/graph/namespaces?refresh=0&namespaces=${namespaces}`);
});

When('user opens display menu', () => {
  cy.get('button#display-settings').click();
});

When('user enables {string} {string} edge labels', (radio, edgeLabel) => {
  cy.get('button#display-settings').get(`input#${edgeLabel}`).check();
  cy.get(`input#${radio}`).check();
});

When('user {string} {string} edge labels', (action, edgeLabel) => {
  if (action === 'enables') {
    cy.get('button#display-settings').get(`input#${edgeLabel}`).check();
  } else {
    cy.get('button#display-settings').get(`input#${edgeLabel}`).uncheck();
  }
});

When('user {string} {string} option', (action, option: string) => {
  let id: string;
  switch (option.toLowerCase()) {
    case 'cluster boxes':
      option = 'boxByCluster';
      break;
    case 'idle edges':
      option = 'filterIdleEdges';
      break;
    case 'idle nodes':
      option = 'filterIdleNodes';
      break;
    case 'missing sidecars':
      option = 'filterSidecars';
      break;
    case 'namespace boxes':
      option = 'boxByNamespace';
      break;
    case 'rank':
      option = 'rank';
      break;
    case 'service nodes':
      option = 'filterServiceNodes';
      break;
    case 'security':
      option = 'filterSecurity';
      break;
    case 'traffic animation':
      option = 'filterTrafficAnimation';
      break;
    case 'virtual services':
      option = 'filterVS';
      break;
    default:
      option = 'xxx';
  }

  if (action === 'enables') {
    cy.get('button#display-settings').get(`input#${option}`).check();
    if (option === 'rank') {
      cy.get(`input#inboundEdges`).check();
    }
  } else {
    cy.get('button#display-settings').get(`input#${option}`).uncheck();
  }
});

///////////////////

Then(`user sees no namespace selected`, () => {
  cy.get('div#empty-graph-no-namespace').should('be.visible');
});

Then(`user sees the {string} namespace`, ns => {
  cy.get('div#summary-panel-graph').find('div#summary-panel-graph-heading').find(`span#ns-${ns}`).should('be.visible');
});

Then('the display menu opens', () => {
  cy.get('button#display-settings').invoke('attr', 'aria-expanded').should('eq', 'true');
});

Then('the display menu has default settings', () => {
  let input = cy.get('button#display-settings').get(`input#responseTime`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#throughput`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#trafficDistribution`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#trafficRate`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#boxByCluster`);
  input.should('exist');
  input.should('be.checked');
  input = cy.get('button#display-settings').get(`input#boxByNamespace`);
  input.should('exist');
  input.should('be.checked');
  input = cy.get('button#display-settings').get(`input#filterHide`);
  input.should('exist');
  input.should('be.checked');
  input = cy.get('button#display-settings').get(`input#filterIdleEdges`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#filterIdleNodes`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#filterOperationNodes`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#rank`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#filterServiceNodes`);
  input.should('exist');
  input.should('be.checked');
  input = cy.get('button#display-settings').get(`input#filterTrafficAnimation`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#filterSidecars`);
  input.should('exist');
  input.should('be.checked');
  input = cy.get('button#display-settings').get(`input#filterSecurity`);
  input.should('exist');
  input.should('not.be.checked');
  input = cy.get('button#display-settings').get(`input#filterVS`);
  input.should('exist');
  input.should('be.checked');
});

Then('the graph reflects default settings', () => {
  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      // no nonDefault edge label info
      let numEdges = state.cy.edges(`[?responseTime],[?throughput]`).length;
      assert.isTrue(numEdges === 0);

      // no idle edges, mtls
      numEdges = state.cy.edges(`[^hasTraffic],[isMTLS > 0]`).length;
      assert.isTrue(numEdges === 0);

      // boxes
      let numNodes = state.cy.nodes(`[isBox = "app"]`).length;
      assert.isTrue(numNodes > 0);
      numNodes = state.cy.nodes(`[isBox = "namespace"]`).length;
      assert.isTrue(numNodes > 0);

      // service nodes
      numNodes = state.cy.nodes(`[nodeType = "service"]`).length;
      assert.isTrue(numNodes > 0);

      // a variety of not-found tests
      numNodes = state.cy.nodes(
        `[isBox = "cluster"],[?isIdle],[?rank],[?hasMissingSC],[?hasVS],[nodeType = "operation"]`
      ).length;
      assert.isTrue(numNodes === 0);
    });
});

Then('user sees {string} edge labels', el => {
  const input = cy.get('button#display-settings').get(`input#${el}`);
  input.should('exist');
  input.should('be.checked');
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  let rate;
  switch (el) {
    case 'trafficDistribution':
      rate = 'httpPercentReq';
      break;
    case 'trafficRate':
      rate = 'http';
      break;
    default:
      rate = el;
  }

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numEdges = state.cy.edges(`[${rate}" > 0]`).length;
      assert.isTrue(numEdges > 0);
    });
});

Then('user sees {string} edge label option is closed', edgeLabel => {
  const input = cy.get('button#display-settings').get(`input#${edgeLabel}`);
  input.should('exist');
  input.should('not.be.checked');
});

Then('user does not see {string} boxing', (boxByType: string) => {
  const input = cy.get('button#display-settings').get(`input#boxBy${boxByType}`);
  input.should('exist');
  input.should('not.be.checked');
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numBoxes = state.cy.nodes(`[isBox = "${boxByType.toLowerCase()}"]`).length;
      assert.isTrue(numBoxes === 0);
    });
});

Then('idle edges {string} in the graph', action => {
  const input = cy.get('button#display-settings').get(`input#filterIdleEdges`);
  input.should('exist');
  if (action === 'appear') {
    input.should('be.checked');
  } else {
    input.should('not.be.checked');
  }
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numEdges = state.cy.edges(`[^hasTraffic]`).length;
      if (action === 'appear') {
        assert.isTrue(numEdges > 0);
      } else {
        assert.isTrue(numEdges === 0);
      }
    });
});

Then('idle nodes {string} in the graph', action => {
  const input = cy.get('button#display-settings').get(`input#filterIdleNodes`);
  input.should('exist');
  if (action === 'appear') {
    input.should('be.checked');
  } else {
    input.should('not.be.checked');
  }
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numNodes = state.cy.nodes(`[?isIdle]`).length;
      if (action === 'appear') {
        assert.isTrue(numNodes > 0);
      } else {
        assert.isTrue(numNodes === 0);
      }
    });
});

Then('ranks {string} in the graph', action => {
  const input = cy.get('button#display-settings').get(`input#rank`);
  input.should('exist');
  if (action === 'appear') {
    input.should('be.checked');
  } else {
    input.should('not.be.checked');
  }
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numNodes = state.cy.nodes(`[rank > 0]`).length;
      if (action === 'appear') {
        assert.isTrue(numNodes > 0);
      } else {
        assert.isTrue(numNodes === 0);
      }
    });
});

Then('user does not see service nodes', () => {
  const input = cy.get('button#display-settings').get(`input#filterServiceNodes`);
  input.should('exist');
  input.should('not.be.checked');
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numBoxes = state.cy.nodes(`[nodeType = "service"][^isOutside]`).length;
      assert.isTrue(numBoxes === 0);
    });
});

Then('security {string} in the graph', action => {
  const input = cy.get('button#display-settings').get(`input#filterSecurity`);
  input.should('exist');
  if (action === 'appears') {
    input.should('be.checked');
  } else {
    input.should('not.be.checked');
  }
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed

  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numEdges = state.cy.edges(`[isMTLS > 0]`).length;
      if (action === 'appears') {
        assert.isTrue(numEdges > 0);
      } else {
        assert.isTrue(numEdges === 0);
      }
    });
});

Then('{string} option {string} in the graph', (option, action) => {
  let id: string;
  switch (option.toLowerCase()) {
    case 'missing sidecars':
      option = 'filterSidecars';
      break;
    case 'traffic animation':
      option = 'filterTrafficAnimation';
      break;
    case 'virtual services':
      option = 'filterVS';
      break;
    default:
      option = 'xxx';
  }

  const input = cy.get('button#display-settings').get(`input#${option}`);
  input.should('exist');
  if (action === 'appears') {
    input.should('be.checked');
  } else {
    input.should('not.be.checked');
  }
  input.should('not.be.disabled'); // this forces a wait, enables when graph is refreshed
});
