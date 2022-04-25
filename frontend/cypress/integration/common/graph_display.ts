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

When('user enables {string} edge labels', edgeLabel => {
  cy.get('button#display-settings').get(`input#${edgeLabel}`).check();
});

When('user disables {string} edge labels', edgeLabel => {
  cy.get('button#display-settings').get(`input#${edgeLabel}`).uncheck();
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
      numEdges = state.cy.edges(`[http = 0],[isMTLS > 0]`).length;
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
      numNodes = state.cy.nodes(`[isBox = "cluster"],[?isIdle],[?rank],[?hasMissingSC],[?hasVS],[nodeType = "operation"]`).length;
      assert.isTrue(numNodes === 0);
    });
});

Then('user sees {string} edge labels', el => {
  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numEdges = state.cy.edges(`[${el} > 0]`).length;
      assert.isTrue(numEdges > 0);
    });
});

Then('user sees {string} edge label option is closed', edgeLabel => {
  const input = cy.get('button#display-settings').get(`input#${edgeLabel}`);
  input.should('exist');
  input.should('not.be.checked');
});
