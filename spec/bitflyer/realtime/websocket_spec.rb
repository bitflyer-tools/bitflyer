# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, open?: true, closed?: false, send: nil, close: nil,
                    close_on_eof: nil, reset_error: nil)
  end
  let(:handlers) { {} }

  before do
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:connect) do
      attempt = @attempts.shift
      raise attempt if attempt

      handlers.fetch(:open).call
    end
    allow($stdout).to receive(:puts)
  end

  after { @client&.shutdown }

  def receive_message(data)
    handlers.fetch(:message).call(double('WebSocket payload', data: data))
  end

  it 'replays subscriptions registered during the initial outage once the session is ready' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    @client = Bitflyer.realtime_client

    events = []
    @client.ticker_btc_jpy = ->(event) { events << event }
    @client.websocket_client.reconnect
    @client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('42["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
  end

  it 'waits for the replacement session before sending new subscriptions' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [nil, nil]
    @client = Bitflyer.realtime_client
    receive_message('0{}')

    allow(socket).to receive(:closed?).and_return(true)
    @client.websocket_client.reconnect
    @client.ticker_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, nil]
    reconnected = Queue.new
    allow(socket).to receive(:close_on_eof) { reconnected << true }

    @client = Bitflyer.realtime_client

    Timeout.timeout(5) { reconnected.pop }
    expect(socket).to have_received(:connect).exactly(3).times
    expect(@client.websocket_client.websocket_client).to eq(socket)
  end

  it 'waits for authentication before replaying private subscriptions' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    @client = Bitflyer.realtime_client('key', 'secret')
    @client.child_order_events = ->(_event) {}
    @client.websocket_client.reconnect

    receive_message('0{}')
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('42["subscribe","child_order_events"]').once
  end

  it 'stops retrying and leaves queued subscriptions unsent when authentication is rejected' do
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    reconnected = Queue.new
    allow(socket).to receive(:close_on_eof) { reconnected << true }
    allow_any_instance_of(described_class).to receive(:start_monitoring).and_wrap_original do |start|
      @monitor = start.call
    end
    @client = Bitflyer.realtime_client('key', 'secret')
    @client.child_order_events = ->(_event) {}
    Timeout.timeout(5) { reconnected.pop }
    allow(socket).to receive(:close) do
      allow(socket).to receive_messages(open?: false, closed?: true)
      handlers.fetch(:close).call(nil)
    end

    receive_message('0{}')
    receive_message('430[{"message":"Invalid API key"}]')

    expect(@monitor.join(5)).to eq(@monitor)
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')
    expect(socket).to have_received(:connect).twice
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'when replacing a socket' do
  let(:original_socket) { instance_double(Bitflyer::Realtime::Transport, closed?: false) }
  let(:replacement_socket) { instance_double(Bitflyer::Realtime::Transport) }
  let(:message_handlers) { {} }

  before do
    [original_socket, replacement_socket].each do |socket|
      allow(socket).to receive_messages(connect: nil, close_on_eof: nil)
      allow(socket).to receive(:on) do |event, &handler|
        message_handlers[socket] = handler if event == :message
      end
    end
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(original_socket, replacement_socket)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @heartbeat_time = 10_000
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @heartbeat_time }
  end

  it 'waits for setup before checking the replacement socket heartbeat' do
    client = described_class.new(host: 'wss://example.test', key: nil, secret: nil)
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    message_handlers.fetch(original_socket).call(setup)

    @heartbeat_time += 3_000
    expect(original_socket).to receive(:close)
    client.wait_pong

    allow(original_socket).to receive(:closed?).and_return(true)
    client.reconnect
    expect(replacement_socket).not_to receive(:send)
    expect(replacement_socket).not_to receive(:close)
    client.wait_pong
    client.send_ping

    message_handlers.fetch(original_socket).call(setup)
    message_handlers.fetch(original_socket).call(Struct.new(:data).new('3'))
    expect(client.ping_interval).to be_nil
    expect(client.ping_timeout).to be_nil
    expect(client.last_ping_at).to be_nil
    expect(client.last_pong_at).to be_nil
  end

  it 'closes the replacement socket when its own heartbeat times out after setup' do
    client = described_class.new(host: 'wss://example.test', key: nil, secret: nil)
    allow(original_socket).to receive(:closed?).and_return(true)
    client.reconnect
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    message_handlers.fetch(replacement_socket).call(setup)

    @heartbeat_time += 3_000
    expect(replacement_socket).to receive(:close)
    client.wait_pong
  end
end

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  subject(:client) { described_class.new(host: 'wss://example.test', key: key, secret: secret) }

  let(:socket) { instance_double(Bitflyer::Realtime::Transport, on: nil, send: nil, close: nil, connect: nil, close_on_eof: nil) }
  let(:key) { nil }
  let(:secret) { nil }

  before do
    @heartbeat_time = 10_000
    @wall_time = Time.at(1_000)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @heartbeat_time }
    allow(Time).to receive(:now) { @wall_time }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
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
