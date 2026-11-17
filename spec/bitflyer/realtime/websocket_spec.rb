# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:transport) { instance_double(WebSocket::Client::Simple::Client, send: nil, open?: false) }
  let(:handlers) { {} }
  let(:ready) { spy('ready callback') }
  let(:subscription_failed) { spy('subscription failure callback') }
  let(:key) { nil }
  let(:secret) { nil }

  before do
    stub_transport(transport, handlers)
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(transport)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
  end

  def stub_transport(socket, events)
    allow(socket).to receive(:on) { |event, &handler| events[event] = handler }
  end

  def receive_frame(frame, events = handlers)
    events.fetch(:message).call(double(data: frame))
  end

  def realtime_client
    Bitflyer.realtime_client(key, secret).tap do |client|
      client.ready = ready
      client.subscription_failed = subscription_failed
    end
  end

  it 'waits for every subscription acknowledgment and ignores duplicates and unknown IDs' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    client.executions_btc_jpy = ->(_message) {}

    receive_frame('0{}')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]')
    expect(transport).to have_received(:send).with('422["subscribe","lightning_executions_BTC_JPY"]')
    expect(ready).not_to have_received(:call)

    receive_frame('432[null]')
    receive_frame('432[null]')
    receive_frame('439[null]')
    expect(ready).not_to have_received(:call)

    receive_frame('431[]')
    receive_frame('431[]')
    expect(ready).to have_received(:call).once
  end

  it 'waits for new acknowledgments after reconnecting and ignores replies from the previous socket' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    receive_frame('431[null]')
    expect(ready).to have_received(:call).once

    next_transport = instance_double(WebSocket::Client::Simple::Client, send: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(next_transport)

    handlers.fetch(:close).call(nil)
    client.websocket_client.reconnect
    receive_frame('0{}', next_handlers)
    receive_frame('431[null]')
    expect(ready).to have_received(:call).once

    receive_frame('431[null]', next_handlers)
    expect(ready).to have_received(:call).twice
  end

  it 'becomes ready immediately when setup has no subscriptions' do
    realtime_client
    receive_frame('0{}')
    expect(ready).to have_received(:call).once
  end

  context 'with credentials' do
    let(:key) { 'key' }
    let(:secret) { 'secret' }

    it 'waits for the private subscription after authentication' do
      client = realtime_client
      client.child_order_events = ->(_message) {}

      receive_frame('0{}')
      expect(transport).to have_received(:send).with(start_with('420["auth",'))
      expect(transport).not_to have_received(:send).with('421["subscribe","child_order_events"]')

      receive_frame('430[null]')
      expect(transport).to have_received(:send).with('421["subscribe","child_order_events"]')
      expect(ready).not_to have_received(:call)

      receive_frame('431[null]')
      receive_frame('430[null]')
      receive_frame('431[null]')
      expect(ready).to have_received(:call).once
    end

    it 'reports a rejected channel and keeps ready pending after the other subscription succeeds' do
      client = realtime_client
      client.child_order_events = ->(_message) {}
      client.ticker_btc_jpy = ->(_message) {}

      receive_frame('0{}')
      receive_frame('430[null]')
      receive_frame('431[{"message":"Access denied"}]')
      receive_frame('431[{"message":"Access denied"}]')
      receive_frame('432[null]')

      expect(subscription_failed).to have_received(:call).with(:child_order_events, { 'message' => 'Access denied' }).once
      expect(ready).not_to have_received(:call)
    end
  end
end
