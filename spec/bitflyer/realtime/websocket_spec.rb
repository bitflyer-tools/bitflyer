# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'pong timeout recovery' do
  it 'reports a disconnected callback error and reconnects after the pong deadline' do
    original = Bitflyer::Realtime::Transport.new
    replacement = Bitflyer::Realtime::Transport.new
    driver = instance_double(WebSocket::Driver::Client, state: :open, on: nil, start: nil, text: nil, close: nil)
    socket = instance_double(OpenSSL::SSL::SSLSocket, close: nil)
    reconnect_attempts = Queue.new
    allow(WebSocket::Driver).to receive(:client).with(original).and_return(driver)
    allow(original).to receive(:connect_tls).and_return(socket)
    allow(original).to receive(:read_messages)
    allow(replacement).to receive(:connect) { |url| reconnect_attempts << url }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(original, replacement)

    client = described_class.new(host: 'wss://example.com', key: nil, secret: nil)
    expect do
      client.disconnected = ->(_) { raise 'callback failed' }
      client.setup_by_response(json: '{}')
      client.last_pong_at = Time.now.to_i - 100

      expect(Timeout.timeout(5) { reconnect_attempts.pop }).to eq('wss://example.com/socket.io/?transport=websocket')
      expect { client.shutdown }.not_to raise_error
    end.to output(/callback failed/).to_stderr
    expect(socket).to have_received(:close).once
  ensure
    client&.shutdown
  end
end

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'WebSocket handshakes' do
  let(:transport_class) { Bitflyer::Realtime::Transport }
  let(:original) { transport_class.new }
  let(:replacement) { transport_class.new }
  let(:client) { described_class.new(host: 'wss://example.com', key: nil, secret: nil) }
  let(:handlers) { Hash.new { |sockets, transport| sockets[transport] = {} } }
  let(:setup_message) { Struct.new(:data).new('0{}') }

  before do
    [original, replacement].each do |transport|
      allow(transport).to receive(:connect)
      allow(transport).to receive_messages(open?: false, closed?: false)
      allow(transport).to receive(:on) { |event, &handler| handlers[transport][event] = handler }
      allow(transport).to receive(:close_for_shutdown) { handlers[transport].fetch(:close).call(nil) }
    end
    allow(transport_class).to receive(:new).and_return(original, replacement)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @now }
    @now = 100_000
  end

  after { client.shutdown }

  it 'exposes the active transport as read-only' do
    expect(client.websocket_client).to equal(original)
    expect(client).not_to respond_to(:websocket_client=)
  end

  it 'keeps a pending handshake on the same socket past the first monitor tick' do
    client.ready = -> { @ready = true }

    @now += 1_000
    client.reconnect
    allow(original).to receive(:open?).and_return(true)
    handlers[original].fetch(:open).call
    handlers[original].fetch(:message).call(setup_message)

    expect(client.websocket_client).to equal(original)
    expect(original).not_to have_received(:close_for_shutdown)
    expect(replacement).not_to have_received(:connect)
    expect(@ready).to be(true)
  end

  it 'closes a timed-out socket before replacing it and ignores its late events' do
    expect(original).to receive(:close_for_shutdown).ordered.and_call_original
    expect(replacement).to receive(:connect).ordered
    disconnected = []
    client.disconnected = ->(error) { disconnected << error }

    @now += 10_000
    client.reconnect
    handlers[original].fetch(:open).call
    handlers[original].fetch(:message).call(setup_message)
    handlers[original].fetch(:close).call(nil)

    expect(client.websocket_client).to equal(replacement)
    expect(client.last_pong_at).to be_nil
    expect(disconnected).to be_empty
  end

  it 'retries a closed socket before its handshake deadline' do
    disconnected = []
    client.disconnected = ->(error) { disconnected << error }
    allow(original).to receive(:closed?).and_return(true)
    handlers[original].fetch(:close).call(nil)
    client.reconnect

    expect(client.websocket_client).to equal(replacement)
    expect(disconnected).to eq([nil])
  end
end

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, open?: true, closed?: false, send: nil, close: nil,
                    close_for_shutdown: nil)
  end
  let(:handlers) { {} }

  before do
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:connect) do
      attempt = @attempts.shift
      raise attempt if attempt

      handlers.fetch(:open).call
      @reconnected&.push(true)
    end
    allow($stdout).to receive(:puts)
  end

  after { @client&.shutdown }

  it 'exposes the realtime client connection as read-only' do
    @attempts = []
    @client = Bitflyer.realtime_client

    expect(@client.websocket_client).to be_a(described_class)
    expect(@client).not_to respond_to(:websocket_client=)
  end

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
    ready = spy('ready callback')
    @client.ready = ready
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

  it 'stops delivering events from the current frame when a subscription callback shuts down' do
    @attempts = [nil]
    @client = Bitflyer.realtime_client
    events = []
    @client.ticker_btc_jpy = lambda do |event|
      events << event
      @client.shutdown
    end
    receive_message('0{}')

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100},{"ltp":101}]')

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
    expect(socket).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, nil]
    @reconnected = Queue.new

    @client = Bitflyer.realtime_client

    Timeout.timeout(5) { @reconnected.pop }
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
    expect(socket).not_to have_received(:send).with('421["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('421["subscribe","child_order_events"]').once

    notifications = []
    @client.ready = -> { notifications << :ready }
    expect(notifications).to be_empty
    receive_message('431[null]')
    expect(notifications).to eq([:ready])
  end

  it 'stops retrying and leaves queued subscriptions unsent when authentication is rejected' do
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    @reconnected = Queue.new
    allow_any_instance_of(described_class).to receive(:start_monitoring).and_wrap_original do |start|
      @monitor = start.call
    end
    @client = Bitflyer.realtime_client('key', 'secret')
    @client.child_order_events = ->(_event) {}
    Timeout.timeout(5) { @reconnected.pop }
    errors = []
    notifications = []
    @client.disconnected = ->(error) { errors << error }
    allow(socket).to receive(:close) do
      allow(socket).to receive_messages(open?: false, closed?: true)
      handlers.fetch(:close).call(nil)
    end

    receive_message('0{}')
    receive_message('430[{"message":"Invalid API key"}]')
    @client.ready = -> { notifications << :ready }

    expect(@monitor.join(5)).to eq(@monitor)
    expect(socket).to have_received(:close).once
    expect(socket).not_to have_received(:send).with('421["subscribe","child_order_events"]')
    expect(socket).to have_received(:connect).twice
    expect(notifications).to be_empty
    expect(errors.map(&:message)).to eq(['Authentication failed: [{"message":"Invalid API key"}]'])
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'when replacing a socket' do
  let(:original_socket) { instance_double(Bitflyer::Realtime::Transport, closed?: false) }
  let(:replacement_socket) { instance_double(Bitflyer::Realtime::Transport) }
  let(:message_handlers) { {} }

  before do
    [original_socket, replacement_socket].each do |socket|
      allow(socket).to receive_messages(connect: nil)
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

  let(:socket) { instance_double(Bitflyer::Realtime::Transport, on: nil, send: nil, close: nil, connect: nil) }
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

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:transport) { instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false) }
  let(:handlers) { {} }
  let(:ready) { spy('ready callback') }
  let(:subscription_failed) { spy('subscription failure callback') }
  let(:key) { nil }
  let(:secret) { nil }

  before do
    stub_transport(transport, handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
  end

  def stub_transport(socket, events)
    allow(socket).to receive(:on) { |event, &handler| events[event] = handler }
    allow(socket).to receive(:connect) { events.fetch(:open).call }
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

  it 'unsubscribes one runtime channel while retaining the others across reconnect' do
    client = Bitflyer.realtime_client('key', 'secret')
    client.ready = ready
    ticker = spy('ticker callback')
    orders = spy('orders callback')
    client.child_order_events = ->(message) { orders.call(message) }
    receive_frame('0{}')
    receive_frame('430[null]')
    receive_frame('431[null]')

    client.subscribe('lightning_ticker_SOL_JPY') { |message| ticker.call(message) }
    expect(transport).to have_received(:send).with('422["subscribe","lightning_ticker_SOL_JPY"]').once
    receive_frame('432[null]')
    receive_frame('42["lightning_ticker_SOL_JPY",1]')

    client.unsubscribe(:lightning_ticker_SOL_JPY)
    client.unsubscribe('lightning_ticker_SOL_JPY')
    expect(transport).to have_received(:send).with('42["unsubscribe","lightning_ticker_SOL_JPY"]').once
    receive_frame('42["lightning_ticker_SOL_JPY",2]')
    receive_frame('42["child_order_events",3]')
    expect(ticker).to have_received(:call).with(1).once
    expect(ticker).to have_received(:call).once
    expect(orders).to have_received(:call).with(3)

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(transport).to receive(:closed?).and_return(true)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)
    client.websocket_client.reconnect
    receive_frame('0{}', next_handlers)
    receive_frame('430[null]', next_handlers)
    receive_frame('431[null]', next_handlers)
    receive_frame('42["child_order_events",4]', next_handlers)

    expect(next_transport).to have_received(:send).with('421["subscribe","child_order_events"]')
    expect(next_transport).to have_received(:send).exactly(2).times
    expect(orders).to have_received(:call).with(4)
    expect(ready).to have_received(:call).twice
  end

  it 'ignores a canceled setup acknowledgment and reports a runtime rejection once' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')

    client.unsubscribe('lightning_ticker_BTC_JPY')
    expect(ready).to have_received(:call).once
    client.subscribe('lightning_ticker_BTC_JPY') { |_message| }
    expect(transport).to have_received(:send).with('422["subscribe","lightning_ticker_BTC_JPY"]')

    receive_frame('431["stale rejection"]')
    receive_frame('432["rejected"]')
    receive_frame('432["rejected"]')
    expect(subscription_failed).to have_received(:call).with(:lightning_ticker_BTC_JPY, 'rejected').once
    expect(subscription_failed).to have_received(:call).once
    expect(ready).to have_received(:call).once
  end

  it 'sends subscription changes in order when a send is in progress' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    subscribe_frame = '421["subscribe","lightning_ticker_BTC_JPY"]'
    unsubscribe_frame = '42["unsubscribe","lightning_ticker_BTC_JPY"]'
    frames = []
    allow(transport).to receive(:send) do |frame|
      client.unsubscribe('lightning_ticker_BTC_JPY') if frame == subscribe_frame
      frames << frame
    end

    receive_frame('0{}')

    expect(frames).to eq([subscribe_frame, unsubscribe_frame])
    expect(ready).to have_received(:call).once
  end

  it 'waits for new acknowledgments after reconnecting and ignores replies from the previous socket' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    receive_frame('431[null]')
    expect(ready).to have_received(:call).once

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)

    allow(transport).to receive(:closed?).and_return(true)
    handlers.fetch(:close).call(nil)
    client.websocket_client.reconnect
    receive_frame('0{}', next_handlers)
    receive_frame('431[null]')
    expect(ready).to have_received(:call).once

    receive_frame('431[null]', next_handlers)
    expect(ready).to have_received(:call).twice
  end

  it 'ignores an acknowledgment that was being read when the socket was replaced' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)

    payload = double('old acknowledgment')
    allow(payload).to receive(:data) do
      allow(transport).to receive(:closed?).and_return(true)
      client.websocket_client.reconnect
      receive_frame('0{}', next_handlers)
      '431[null]'
    end
    handlers.fetch(:message).call(payload)

    expect(next_transport).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]')
    expect(ready).not_to have_received(:call)

    receive_frame('431[null]', next_handlers)
    expect(ready).to have_received(:call).once
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

      receive_frame('430[ null ]')
      expect(transport).to have_received(:send).with('421["subscribe","child_order_events"]')
      expect(ready).not_to have_received(:call)

      receive_frame("431[\n  null\n]")
      expect(ready).to have_received(:call).once

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

describe Bitflyer::Realtime::WebSocketClient, 'packet handling' do
  let(:socket) { instance_double(Bitflyer::Realtime::Transport, on: nil, send: nil, close: nil, connect: nil, open?: true) }
  let(:host) { 'wss://example.test' }
  let(:key) { nil }
  let(:secret) { nil }
  let(:client) { described_class.new(host: host, key: key, secret: secret) }
  let(:ready) { double('ready callback', call: nil) }

  before do
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:on).with(:message) { |&callback| @receive = callback }
    allow_any_instance_of(described_class).to receive(:start_monitoring)
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

  it 'logs a fixed diagnostic for a malformed private event and delivers the next event' do
    callback = spy('private order callback')
    client.subscribe(channel_name: :child_order_events) { |message| callback.call(message) }

    expect do
      receive_frame('42["child_order_events",{"order_id":INVALID"demo-private-order"}]')
    end.to output("Invalid JSON in realtime frame\n").to_stdout
    expect(callback).not_to have_received(:call)

    receive_frame('42["child_order_events",{"order_id":"valid-order"}]')
    expect(callback).to have_received(:call).with({ 'order_id' => 'valid-order' }).once
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
