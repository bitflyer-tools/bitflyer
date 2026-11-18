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
end

describe Bitflyer::Realtime::WebSocketClient, 'packet handling' do
  let(:socket) { double('WebSocket', on: nil, send: nil, close: nil) }
  let(:host) { 'wss://example.test' }
  let(:key) { nil }
  let(:secret) { nil }
  let(:client) { described_class.new(host: host, key: key, secret: secret) }
  let(:ready) { double('ready callback', call: nil) }

  before do
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
    allow(socket).to receive(:on).with(:message) { |&callback| @receive = callback }
    allow(Thread).to receive(:new)
    client.ready = ready
  end

  def receive_frame(data)
    @receive.call(double('frame', data: data))
  end

  it 'sets heartbeat intervals and signals readiness on handshake' do
    receive_frame('0{"pingInterval":10000,"pingTimeout":5000}')

    expect(client.ping_interval).to eq(10_000)
    expect(client.ping_timeout).to eq(5_000)
    expect(ready).to have_received(:call).once
  end

  it 'updates the last pong time on a heartbeat response' do
    allow(Time).to receive(:now).and_return(Time.at(123))

    receive_frame('3')

    expect(client.last_pong_at).to eq(123)
  end

  it 'closes the socket on disconnect' do
    receive_frame('41')

    expect(socket).to have_received(:close).once
  end

  it 'delivers the complete decoded large board event to its callback' do
    callback = double('board callback', call: nil)
    channel = :lightning_board_BTC_JPY
    board = {
      'mid_price' => 5_000_000,
      'bids' => Array.new(3_000) { |index| { 'price' => 5_000_000 - index, 'size' => 0.125 } },
      'asks' => [{ 'price' => 5_000_001, 'size' => 0.25 }]
    }
    client.subscribe(channel_name: channel) { |message| callback.call(message) }

    receive_frame("42#{JSON.pretty_generate([channel, board])}")

    expect(callback).to have_received(:call).with(board).once
  end

  context 'with API credentials' do
    let(:key) { 'key' }
    let(:secret) { 'secret' }

    it 'requests authentication on handshake and signals readiness on acknowledgement' do
      receive_frame('0{}')

      expect(socket).to have_received(:send).with(start_with('420["auth",')).once
      expect(ready).not_to have_received(:call)

      receive_frame('430[null]')

      expect(ready).to have_received(:call).once
    end
  end
end
