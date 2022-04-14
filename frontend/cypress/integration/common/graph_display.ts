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

When('user enables {string} {string} edge labels', (percentile, edgeLabel) => {
  cy.get('button#display-settings').get(`input#${edgeLabel}`).check();
  cy.get(`input#${percentile}`).check();
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

Then('user sees {string} edge labels', el => {
  cy.waitForReact(1000, '#root');
  cy.getReact('CytoscapeGraph')
    .getCurrentState()
    .then(state => {
      const numEdges = state.cy.edges(`[?${el}]`).length;
      assert.isTrue(numEdges > 0);
    });
});
