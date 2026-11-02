import { act, fireEvent, render, waitFor } from '@testing-library/react';
import type { Mock } from '@rstest/core';
import type { Map as ImmutableMap } from 'immutable';
import { Provider } from 'react-redux';
import { store } from 'store/ConfigStore';
import { ChatAIActions } from 'actions/ChatAIActions';
import { Prompt } from '../Prompt';
import { ChatBotContent } from '../ChatBotContent';
import * as API from 'services/Api';

// lodash-es stubs: replace with equivalent inline implementations so the module loads correctly.
rstest.mock('lodash-es', () => ({
  throttle: (fn: (...args: unknown[]) => unknown) => fn,
  uniqueId: (() => {
    let counter = 0;
    return (prefix = '') => `${prefix}${++counter}`;
  })()
}));

rstest.mock('services/Api', () => ({
  postChatAI: rstest.fn(),
  getChatPrompts: rstest.fn()
}));

rstest.mock('react-router-dom-v5-compat', () => ({
  useLocation: () => ({ pathname: '/overview' })
}));

rstest.mock('app/History', () => ({
  router: { navigate: rstest.fn() }
}));

rstest.mock('../hooks/useLocationContext', () => ({
  useLocationContext: () => [undefined, undefined, undefined, undefined]
}));

rstest.mock('../hooks/useChatResourceHealth', () => ({
  useChatResourceHealth: () => undefined
}));

rstest.mock('../EntryChat/ToolModal', () => ({
  ToolModal: () => null
}));

rstest.mock('../EntryChat/EntryChat', () => ({ EntryChat: () => null }));

// Lightweight MessageBar stub: textarea + send button for prompt/context tests.
rstest.mock('@patternfly/chatbot', () => {
  const ReactModule = require('react');
  return {
    ChatbotDisplayMode: { default: 'default', docked: 'docked', embedded: 'embedded', fullscreen: 'fullscreen' },
    ChatbotContent: ({ children }: { children: React.ReactNode }) => children,
    MessageBox: ({ children }: { children: React.ReactNode }) => children,
    ChatbotWelcomePrompt: ({ prompts }: { prompts: { onClick: () => void; title: string }[] }) =>
      ReactModule.createElement('button', { onClick: prompts[0].onClick }, prompts[0].title),
    MessageBar: ({
      innerRef,
      isSendButtonDisabled,
      onChange,
      onSendMessage,
      value
    }: {
      innerRef?: React.RefObject<HTMLTextAreaElement>;
      isSendButtonDisabled?: boolean;
      onChange?: (e: { target: { value: string } }) => void;
      onSendMessage?: () => void;
      value?: string;
    }) =>
      ReactModule.createElement(
        ReactModule.Fragment,
        null,
        ReactModule.createElement('textarea', {
          'data-test': 'mock-prompt-input',
          onChange: (e: { target: { value: string } }) => onChange?.(e),
          ref: innerRef,
          defaultValue: value ?? ''
        }),
        ReactModule.createElement(
          'button',
          {
            'data-test': 'mock-send-button',
            disabled: isSendButtonDisabled,
            onClick: onSendMessage
          },
          'Send'
        )
      )
  };
});

const renderPrompt = (withWelcome = false): ReturnType<typeof render> =>
  render(
    <Provider store={store}>
      {withWelcome && <ChatBotContent chatHistoryEndRef={{ current: null }} />}
      <Prompt scrollIntoView={rstest.fn()} />
    </Provider>
  );

describe('Prompt error handling', () => {
  beforeEach(() => {
    rstest.clearAllMocks();
    store.dispatch(ChatAIActions.setChatHistoryClear());
    (API.getChatPrompts as Mock).mockResolvedValue({ data: [] });
  });

  it('dispatches an error entry when the API returns a non-200 status', async () => {
    (API.postChatAI as Mock).mockResolvedValue({
      status: 500,
      statusText: 'Internal Server Error',
      body: null
    });

    store.dispatch(ChatAIActions.setQuery('What is the mesh status?'));

    const { getByTestId } = renderPrompt();

    await act(async () => {
      fireEvent.click(getByTestId('mock-send-button'));
    });

    await waitFor(() => {
      const lastEntry = store.getState().ai.chat.chatHistory.last() as ImmutableMap<string, unknown> | undefined;
      expect(lastEntry?.get('isStreaming')).toBe(false);
      const error = lastEntry?.get('error') as { message: string } | undefined;
      expect(error).toBeDefined();
      expect(error?.message).toContain('Internal Server Error');
      expect(lastEntry?.get('who')).toBe('ai');
    });
  });

  it('dispatches an error entry when the stream throws a non-AbortError', async () => {
    const networkError = new Error('Network connection lost');
    networkError.name = 'TypeError';
    (API.postChatAI as Mock).mockRejectedValue(networkError);

    store.dispatch(ChatAIActions.setQuery('What is the mesh status?'));

    const { getByTestId } = renderPrompt();

    await act(async () => {
      fireEvent.click(getByTestId('mock-send-button'));
    });

    await waitFor(() => {
      const lastEntry = store.getState().ai.chat.chatHistory.last() as ImmutableMap<string, unknown> | undefined;
      expect(lastEntry?.get('isStreaming')).toBe(false);
      expect(lastEntry?.get('error')).toBeDefined();
      expect(lastEntry?.get('who')).toBe('ai');
    });
  });

  it('does not dispatch an error entry when the stream is aborted by the user', async () => {
    const abortError = new Error('The user aborted a request');
    abortError.name = 'AbortError';
    (API.postChatAI as Mock).mockRejectedValue(abortError);

    store.dispatch(ChatAIActions.setQuery('Cancel me'));

    const { getByTestId } = renderPrompt();

    await act(async () => {
      fireEvent.click(getByTestId('mock-send-button'));
    });

    // AbortError is silently ignored — the AI entry keeps its state from the cancel action,
    // and no additional error field is set by the catch handler.
    await waitFor(() => {
      const lastEntry = store.getState().ai.chat.chatHistory.last() as ImmutableMap<string, unknown> | undefined;
      expect(lastEntry?.get('error')).toBeUndefined();
    });
  });
});

describe('Prompt health-history chat context', () => {
  beforeEach(() => {
    rstest.clearAllMocks();
    store.dispatch(ChatAIActions.setChatHistoryClear());
    store.dispatch(ChatAIActions.setChatContext(''));
    store.dispatch(ChatAIActions.setQuery(''));
    (API.getChatPrompts as Mock).mockResolvedValue({ data: [] });
    (API.postChatAI as Mock).mockResolvedValue({ status: 500, statusText: 'Test response', body: null });
  });

  it('clears supplemental chat context when the user edits the pre-filled prompt', async () => {
    store.dispatch(ChatAIActions.setChatContext('Health history investigation: MCP tools'));
    store.dispatch(ChatAIActions.setQuery('Pre-filled health history prompt'));

    const { getByTestId } = renderPrompt();

    expect(store.getState().ai.chat.chatContext).toContain('Health history investigation');

    await act(async () => {
      fireEvent.change(getByTestId('mock-prompt-input'), {
        target: { value: 'Pre-filled health history prompt edited' }
      });
    });

    expect(store.getState().ai.chat.chatContext).toBe('');
    expect(store.getState().ai.chat.query).toBe('Pre-filled health history prompt edited');
  });

  it('clears supplemental chat context when the user clears the pre-filled prompt', async () => {
    store.dispatch(ChatAIActions.setChatContext('Health history investigation: MCP tools'));
    store.dispatch(ChatAIActions.setQuery('Pre-filled health history prompt'));

    const { getByTestId } = renderPrompt();

    await act(async () => {
      fireEvent.change(getByTestId('mock-prompt-input'), { target: { value: '' } });
    });

    expect(store.getState().ai.chat.chatContext).toBe('');
    expect(store.getState().ai.chat.query).toBe('');
  });

  it('sends supplemental context once without adding it to the displayed user message', async () => {
    store.dispatch(ChatAIActions.setChatContext('Health history investigation: 2026-11-01T05:30:00.000Z'));
    store.dispatch(ChatAIActions.setQuery('Investigate reviews'));
    const { getByTestId } = renderPrompt();

    await act(async () => {
      fireEvent.click(getByTestId('mock-send-button'));
    });

    expect(API.postChatAI).toHaveBeenCalledTimes(1);
    expect((API.postChatAI as Mock).mock.calls[0][2].query).toBe(
      'Context: Health history investigation: 2026-11-01T05:30:00.000Z\n\nInvestigate reviews'
    );
    expect(store.getState().ai.chat.chatHistory.first()?.get('text')).toBe('Investigate reviews');
    expect(store.getState().ai.chat.chatContext).toBe('');
  });

  it('discards investigation context when the welcome prompt replaces the draft', async () => {
    store.dispatch(ChatAIActions.setChatContext('Health history investigation: reviews yesterday'));
    store.dispatch(ChatAIActions.setQuery('Investigate reviews'));
    const { getByRole, getByTestId } = renderPrompt(true);

    await act(async () => {
      fireEvent.click(getByRole('button', { name: 'What can you help me with?' }));
    });
    await act(async () => {
      fireEvent.click(getByTestId('mock-send-button'));
    });

    expect((API.postChatAI as Mock).mock.calls[0][2].query).toBe('What can you help me with in Kiali?');
  });

  it('syncs an external prefill, caps its height, and resets the field when cleared', async () => {
    const { getByTestId } = renderPrompt();
    const input = getByTestId('mock-prompt-input') as HTMLTextAreaElement;
    Object.defineProperty(input, 'scrollHeight', { configurable: true, value: 240 });
    // Mark the uncontrolled field as edited before an external prompt replaces it.
    fireEvent.change(input, { target: { value: 'Old draft' } });

    act(() => store.dispatch(ChatAIActions.setQuery('A long prefilled investigation')));

    expect(input.value).toBe('A long prefilled investigation');
    await waitFor(() => expect(input.style.overflowY).toBe('auto'));
    expect(parseFloat(input.style.height)).toBeLessThan(240);

    fireEvent.change(input, { target: { value: '' } });
    await waitFor(() => expect(input.style.height).toBe(''));
    expect(input.style.overflowY).toBe('hidden');
  });
});
