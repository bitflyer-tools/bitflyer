# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

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

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'outage recovery' do
  let(:socket) { instance_double(WebSocket::Client::Simple::Client, open?: true, send: nil) }
  let(:ticks) { Queue.new }
  let(:waiting) { Queue.new }
  let(:handlers) { {} }

  before do
    tick_queue = ticks
    waiting_queue = waiting
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(WebSocket::Client::Simple).to receive(:connect) do
      attempt = @attempts.shift
      raise attempt if attempt.is_a?(Exception)

      attempt
    end
    allow_any_instance_of(described_class).to receive(:sleep) do
      waiting_queue.push(Thread.current)
      tick_queue.pop
    end
    allow($stdout).to receive(:puts)
  end

  after do
    @monitor&.kill
    @monitor&.join
  end

  def wait_for_monitor
    @monitor = Timeout.timeout(5) { waiting.pop }
  end

  def tick_monitor
    ticks.push(true)
    wait_for_monitor
  end

  def receive_message(data)
    handlers.fetch(:message).call(double('WebSocket payload', data: data))
  end

  it 'replays subscriptions registered during the initial outage once the session is ready' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    events = []
    client.ticker_btc_jpy = ->(event) { events << event }
    tick_monitor
    ready = spy('ready callback')
    client.ready = ready
    client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('422["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
    receive_message('431[null]')
    expect(ready).not_to have_received(:call)
    receive_message('432[null]')
    expect(ready).to have_received(:call).once
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    tick_monitor
    expect(@monitor).to be_alive
    expect(client.websocket_client.websocket_client).to be_nil

    tick_monitor
    expect(client.websocket_client.websocket_client).to eq(socket)
  end

  it 'waits for authentication before replaying private subscriptions' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client('key', 'secret')
    wait_for_monitor
    client.child_order_events = ->(_event) {}
    tick_monitor

    receive_message('0{}')
    expect(socket).not_to have_received(:send).with('421["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('421["subscribe","child_order_events"]').once
  end
end
