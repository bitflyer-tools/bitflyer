# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

describe Bitflyer::Realtime::WebSocketClient do
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

  it 'stops retrying and leaves queued subscriptions unsent when authentication is rejected' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client('key', 'secret')
    wait_for_monitor
    client.child_order_events = ->(_event) {}
    tick_monitor
    allow(socket).to receive(:close) do
      allow(socket).to receive(:open?).and_return(false)
      handlers.fetch(:close).call(nil)
    end

    receive_message('0{}')
    receive_message('430[{"message":"Invalid API key"}]')
    ticks.push(true)

    expect(@monitor.join(5)).to eq(@monitor)
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')
    expect(WebSocket::Client::Simple).to have_received(:connect).twice
  end
end
