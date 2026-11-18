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

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  subject(:client) { described_class.new(host: 'wss://example.test', key: key, secret: secret) }

  let(:socket) { instance_double(WebSocket::Client::Simple::Client, on: nil, send: nil, close: nil) }
  let(:key) { nil }
  let(:secret) { nil }

  before do
    @heartbeat_time = 10_000
    @wall_time = Time.at(1_000)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @heartbeat_time }
    allow(Time).to receive(:now) { @wall_time }
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    client.setup_by_response(json: '{"pingInterval":1500,"pingTimeout":750}')
  end

  it 'sends a ping at each elapsed interval despite wall-clock changes' do
    @wall_time += 60
    @heartbeat_time += 1_499
    client.send_ping
    expect(socket).not_to have_received(:send)

    @wall_time -= 160
    @heartbeat_time += 1
    client.send_ping
    client.send_ping
    expect(socket).to have_received(:send).with('2').once

    @heartbeat_time += 1_500
    client.send_ping
    expect(socket).to have_received(:send).with('2').twice
  end

  it 'closes the socket at the elapsed pong deadline despite wall-clock changes' do
    @wall_time += 60
    @heartbeat_time += 2_249
    client.wait_pong
    expect(socket).not_to have_received(:close)

    @wall_time -= 160
    @heartbeat_time += 1
    client.wait_pong
    expect(socket).to have_received(:close).once
  end

  it 'restarts the pong deadline when a pong is received' do
    @heartbeat_time += 1_500
    client.receive_pong

    @heartbeat_time += 2_249
    client.wait_pong
    expect(socket).not_to have_received(:close)

    @heartbeat_time += 1
    client.wait_pong
    expect(socket).to have_received(:close).once
  end

  it 'exposes handshake, ping, and pong timestamps in Unix seconds' do
    expect(client.last_ping_at).to eq(1_000)
    expect(client.last_pong_at).to eq(1_000)

    @wall_time = Time.at(900, 500_000)
    @heartbeat_time += 1_500
    client.send_ping
    expect(client.last_ping_at).to eq(900)

    @wall_time += 200
    client.receive_pong
    expect(client.last_pong_at).to eq(1_100)
  end

  it 'applies Unix-second writes to both deadlines despite later wall-clock changes' do
    client.last_ping_at = client.last_pong_at = 999
    expect(client.last_ping_at).to eq(999)
    expect(client.last_pong_at).to eq(999)

    @wall_time += 60
    @heartbeat_time += 499
    client.send_ping
    client.wait_pong
    expect(socket).not_to have_received(:send)
    expect(socket).not_to have_received(:close)

    @heartbeat_time += 1
    client.send_ping
    expect(socket).to have_received(:send).with('2').once

    @wall_time -= 160
    @heartbeat_time += 750
    client.wait_pong
    expect(socket).to have_received(:close).once
  end

  it 'clears both deadlines when the timestamps are set to nil' do
    client.last_ping_at = client.last_pong_at = nil
    expect(client.last_ping_at).to be_nil
    expect(client.last_pong_at).to be_nil

    @heartbeat_time += 3_000
    client.send_ping
    client.wait_pong
    expect(socket).not_to have_received(:send)
    expect(socket).not_to have_received(:close)
  end

  context 'with credentials' do
    let(:key) { 'key' }
    let(:secret) { 'secret' }

    it 'uses Unix seconds for the authentication timestamp' do
      expect(socket).to have_received(:send).with(start_with('420')) do |frame|
        event, params = JSON.parse(frame.delete_prefix('420'))
        expect(event).to eq('auth')
        expect(params.fetch('timestamp')).to eq(1_000)
      end
    end
  end
end
