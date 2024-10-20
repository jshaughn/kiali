import React from 'react';
import { Button, ButtonVariant, Modal, ModalVariant } from '@patternfly/react-core';
import { DestinationRuleC, VirtualService } from '../../types/IstioObjects';

type Props = {
  destinationRules: DestinationRuleC[];
  virtualServices: VirtualService[];
  isOpen: boolean;
  onCancel: () => void;
  onConfirm: () => void;
};

const ConfirmDeleteTrafficRoutingModal: React.FunctionComponent<Props> = props => {
  function hasAnyPeerAuthn(drs: DestinationRuleC[]): boolean {
    return drs.filter(dr => !!dr.hasPeerAuthentication()).length > 0;
  }

  function getDeleteMessage() {
    const deleteMessage = 'Are you sure you want to delete ?';
    const deleteItems: JSX.Element[] = [];

    let i = 0;
    let vsMessage =
      props.virtualServices.length > 0
        ? `VirtualService${props.virtualServices.length > 1 ? 's' : ''}: '${props.virtualServices.map(
            vs => vs.metadata.name
          )}'`
        : '';
    deleteItems.push(<div key={`delete_item_${++i}`}>{vsMessage}</div>);

    let drMessage =
      props.destinationRules.length > 0
        ? `DestinationRule${props.destinationRules.length > 1 ? 's' : ''}: '${props.destinationRules.map(
            dr => dr.metadata.name
          )}'`
        : '';
    deleteItems.push(<div key={`delete_item_${++i}`}>{drMessage}</div>);

    let paMessage =
      props.destinationRules.length > 0 && hasAnyPeerAuthn(props.destinationRules)
        ? `PeerAuthentication${props.destinationRules.length > 1 ? 's' : ''}: '${props.destinationRules.map(
            dr => dr.metadata.name
          )}'`
        : '';
    deleteItems.push(<div key={`delete_item_${++i}`}>{paMessage}</div>);

    return (
      <>
        <div key="delete_items" style={{ marginBottom: 5 }}>
          {deleteMessage}
        </div>
        {deleteItems}
      </>
    );
  }

  return (
    <Modal
      variant={ModalVariant.small}
      title="Confirm Delete Traffic Routing ?"
      isOpen={props.isOpen}
      onClose={props.onCancel}
      data-test="delete-traffic-routing-modal"
      actions={[
        <Button key="confirm" variant={ButtonVariant.danger} onClick={props.onConfirm} data-test={'confirm-delete'}>
          Delete
        </Button>,
        <Button key="cancel" variant={ButtonVariant.secondary} isInline onClick={props.onCancel}>
          Cancel
        </Button>
      ]}
    >
      {getDeleteMessage()}
    </Modal>
  );
};

export default ConfirmDeleteTrafficRoutingModal;
