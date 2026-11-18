# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:socket_class) do
    Class.new do
      attr_accessor :open

      def initialize
        @handlers = {}
      end

      def on(event, &handler)
        @handlers[event] = handler
      end

      def emit(event, payload)
        instance_exec(payload, &@handlers.fetch(event))
      end

      def open?
        @open && !closed?
      end

      def closed?
        !!@closed
      end

      def close
        return if closed?

        @closed = true
        emit(:close, nil)
      end
    end
  end

  let(:original) { socket_class.new }
  let(:replacement) { socket_class.new }
  let(:transport) { WebSocket::Client::Simple }
  let(:client) { described_class.new(host: 'wss://example.com', key: nil, secret: nil) }
  let(:setup_message) { Struct.new(:data).new('0{}') }

  before do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0)
  end

  it 'keeps a pending handshake on the same socket past the first monitor tick' do
    expect(transport).to receive(:connect).once.and_yield(original).and_return(original)
    client.ready = ready = double
    expect(ready).to receive(:call).once

    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(101.0)
    client.reconnect
    original.open = true
    original.emit(:message, setup_message)
    client.reconnect

    expect(client.websocket_client).to equal(original)
    expect(original).not_to be_closed
  end

  it 'closes a timed-out socket before replacing it and ignores its late events' do
    expect(transport).to receive(:connect).ordered.and_yield(original).and_return(original)
    expect(original).to receive(:close).ordered.and_call_original
    expect(transport).to receive(:connect).ordered.and_yield(replacement).and_return(replacement)
    client.ready = ready = double
    client.disconnected = disconnected = double
    expect(ready).to receive(:call).once
    expect(disconnected).not_to receive(:call)

    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(110.0)
    client.reconnect
    original.emit(:message, setup_message)
    original.emit(:error, Errno::ECONNRESET.new)
    original.emit(:close, nil)
    expect(client.last_pong_at).to be_nil

    replacement.open = true
    replacement.emit(:message, setup_message)
    expect(client.websocket_client).to equal(replacement)
  end

  it 'retries a closed socket before its handshake deadline' do
    expect(transport).to receive(:connect).ordered.and_yield(original).and_return(original)
    expect(transport).to receive(:connect).ordered.and_yield(replacement).and_return(replacement)
    client.disconnected = disconnected = double
    expect(disconnected).to receive(:call).with(nil)

    original.close
    client.reconnect

    expect(client.websocket_client).to equal(replacement)
  end
end

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) { instance_double(WebSocket::Client::Simple::Client, open?: true, send: nil) }
  let(:ticks) { Queue.new }
  let(:waiting) { Queue.new }
  let(:handlers) { {} }

  before do
    tick_queue = ticks
    waiting_queue = waiting
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(WebSocket::Client::Simple).to receive(:connect) do |_url, &configure|
      attempt = @attempts.shift
      raise attempt if attempt.is_a?(Exception)

      configure.call(attempt)
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
    client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('42["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
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
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('42["subscribe","child_order_events"]').once
  end
end
