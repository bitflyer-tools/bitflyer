# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'pong timeout recovery' do
  it 'reports a disconnected callback error and reconnects after the pong deadline' do
    original = Bitflyer::Realtime::Transport.new
    replacement = Bitflyer::Realtime::Transport.new
    driver = instance_double(WebSocket::Driver::Client, state: :open, on: nil, start: nil, text: true, close: nil)
    socket = instance_double(OpenSSL::SSL::SSLSocket, close: nil)
    reconnect_attempts = Queue.new
    warnings = Queue.new
    allow(WebSocket::Driver).to receive(:client).with(original).and_return(driver)
    allow(original).to receive(:connect_tls).and_return(socket)
    allow(original).to receive(:read_messages)
    allow(replacement).to receive(:connect) { |url| reconnect_attempts << url }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(original, replacement)

    client = described_class.new(host: 'wss://example.com', key: nil, secret: nil)
    allow(client).to receive(:warn).and_wrap_original do |warn, message|
      warn.call(message)
      warnings << true
    end
    expect do
      client.disconnected = ->(_) { raise 'callback failed' }
      client.setup_by_response(json: '{"pingInterval":1,"pingTimeout":1}')
      client.last_ping_at = Time.now.to_i - 1

      expect(Timeout.timeout(5) { reconnect_attempts.pop }).to eq('wss://example.com/socket.io/?transport=websocket')
      expect(warnings.pop(timeout: 5)).to be(true)
      expect { client.shutdown }.not_to raise_error
    end.to output(/callback failed/).to_stderr
    expect(socket).to have_received(:close).once
  ensure
    client&.shutdown
  end
end

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'blocked disconnect callbacks' do
  [:reader, :pong_timeout].each do |trigger|
    it "reaches readiness on a replacement while the #{trigger} disconnect callback is blocked" do
      original = Bitflyer::Realtime::Transport.new
      replacement = Bitflyer::Realtime::Transport.new
      driver = instance_double(WebSocket::Driver::Client, state: :open, on: nil, start: nil, text: true, close: nil)
      socket = instance_double(OpenSSL::SSL::SSLSocket)
      eof = Queue.new
      release = Queue.new
      disconnected = Queue.new
      ready = Queue.new
      reconnected = Queue.new
      allow(socket).to receive(:readpartial) { eof.pop; raise EOFError }
      allow(socket).to receive(:close) { eof << true }
      allow(WebSocket::Driver).to receive(:client).with(original).and_return(driver)
      allow(original).to receive(:connect_tls).and_return(socket)
      allow(replacement).to receive_messages(connect: nil, closed?: false)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(original, replacement)

      client = described_class.new(host: 'wss://example.com', key: nil, secret: nil)
      allow(client).to receive(:reconnect).and_wrap_original do |reconnect|
        reconnect.call
        reconnected << client.websocket_client
      end
      client.ready = -> { ready << client.websocket_client }
      client.disconnected = lambda do |error|
        disconnected << [error, original.reconnectable?, client.instance_variable_get(:@session_ready), Thread.current]
        release.pop
      end
      client.setup_by_response(json: '{"pingInterval":1,"pingTimeout":1}')
      expect(ready.pop(timeout: 5)).to equal(original)

      if trigger == :reader
        eof << true
      else
        client.last_ping_at = Time.now.to_i - 1
      end

      notification = disconnected.pop(timeout: 5)
      expect(notification).to match([nil, true, false, an_instance_of(Thread)])
      callback_thread = notification.last
      expect(reconnected.pop(timeout: 5)).to equal(replacement)
      client.setup_by_response(json: '{}', socket: replacement)
      expect(ready.pop(timeout: 5)).to equal(replacement)
      expect(callback_thread).to be_alive
      expect(original.thread.join(5)).to equal(original.thread)
      original.close
      expect(socket).to have_received(:close).once
      expect(disconnected).to be_empty
    ensure
      release << true
      eof << true
      client&.shutdown
      original&.thread&.join(5)
      callback_thread&.join(5)
    end
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
      allow(transport).to receive_messages(open?: false, closed?: false, reconnectable?: false)
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

  it 'keeps a pending handshake on the same socket across monitor ticks beyond the former client timeout' do
    notifications = Queue.new
    client.ready = -> { notifications << true }

    11.times do
      @now += 1_000
      client.__send__(:poll_transport)
      client.reconnect
    end
    allow(original).to receive(:open?).and_return(true)
    handlers[original].fetch(:open).call
    handlers[original].fetch(:message).call(setup_message)

    expect(client.websocket_client).to equal(original)
    expect(original).not_to have_received(:close_for_shutdown)
    expect(replacement).not_to have_received(:connect)
    expect(notifications.pop(timeout: 5)).to be(true)
  end

  it 'retries a closed socket and ignores its late events' do
    disconnected = Queue.new
    client.disconnected = ->(error) { disconnected << error }
    allow(original).to receive(:reconnectable?).and_return(true)
    handlers[original].fetch(:close).call(nil)
    client.reconnect
    handlers[original].fetch(:open).call
    handlers[original].fetch(:message).call(setup_message)
    handlers[original].fetch(:close).call(nil)

    expect(client.websocket_client).to equal(replacement)
    expect(client.last_pong_at).to be_nil
    expect(Timeout.timeout(5) { disconnected.pop }).to be_nil
    expect(disconnected).to be_empty
  end

  it 'delivers only the latest pending close on the same worker after a burst of reconnects' do
    notifications = Queue.new
    release = Queue.new
    first_error = IOError.new('first close')
    allow(transport_class).to receive(:new).and_return(*([original, replacement] * 11))
    [original, replacement].each { |transport| allow(transport).to receive(:reconnectable?).and_return(true) }
    client.disconnected = lambda do |error|
      notifications << [error, Thread.current]
      release.pop if error.equal?(first_error)
    end

    handlers[original].fetch(:close).call(first_error)
    first_notification = notifications.pop(timeout: 5)
    expect(first_notification).to match([first_error, an_instance_of(Thread)])
    worker = first_notification.last

    errors = Array.new(20) { |index| IOError.new("close #{index}") }
    errors.each do |error|
      previous = client.websocket_client
      client.reconnect
      expect(client.websocket_client).not_to equal(previous)
      handlers[client.websocket_client].fetch(:close).call(error)
    end

    expect(worker).to be_alive
    expect(notifications).to be_empty
    release << true
    expect(worker.join(5)).to equal(worker)
    expect(notifications.pop(timeout: 5)).to eq([errors.last, worker])
    expect(notifications).to be_empty

    client.reconnect
    handlers[client.websocket_client].fetch(:close).call(nil)
    expect(notifications.pop(timeout: 5)).to match([nil, an_instance_of(Thread)])
  ensure
    release << true
    worker&.join(5)
  end

  it 'keeps the replacement setup deadline when an old setup frame is already being dispatched' do
    allow(replacement).to receive(:close)
    client.ready = -> { @ready = true }
    payload = double(data: nil)
    allow(payload).to receive(:data) do
      allow(original).to receive(:reconnectable?).and_return(true)
      client.reconnect
      handlers[replacement].fetch(:open).call
      '0{}'
    end

    handlers[original].fetch(:message).call(payload)

    expect(@ready).to be_nil
    @now += 10_000
    expect(client.__send__(:session_expired?, replacement)).to be(true)
    expect(replacement).to have_received(:close).once
  end

  context 'with credentials' do
    let(:client) { described_class.new(host: 'wss://example.com', key: 'key', secret: 'secret') }

    ['430[null]', '430["denied"]'].each do |frame|
      it "keeps the replacement authentication deadline when dispatching an old #{frame} frame" do
        allow(original).to receive(:send)
        allow(replacement).to receive_messages(send: nil, close: nil)
        client.ready = -> { @ready = true }
        handlers[original].fetch(:open).call
        handlers[original].fetch(:message).call(setup_message)
        payload = double(data: nil)
        allow(payload).to receive(:data) do
          allow(original).to receive(:reconnectable?).and_return(true)
          client.reconnect
          handlers[replacement].fetch(:open).call
          handlers[replacement].fetch(:message).call(setup_message)
          frame
        end

        handlers[original].fetch(:message).call(payload)

        expect(@ready).to be_nil
        expect(replacement).not_to have_received(:close)
        @now += 10_000
        expect(client.__send__(:session_expired?, replacement)).to be(true)
        expect(replacement).to have_received(:close).once
      end
    end
  end

  it 'starts the setup deadline when a pending WebSocket opens' do
    expect(client.websocket_client).to equal(original)
    allow(original).to receive(:open?).and_return(true)
    allow(original).to receive(:close)

    @now += 9_000
    handlers[original].fetch(:open).call

    @now += 1_000
    client.__send__(:poll_transport)
    expect(original).not_to have_received(:close)

    @now += 9_000
    client.__send__(:poll_transport)
    expect(original).to have_received(:close).once
  end
end

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, open?: true, closed?: false, reconnectable?: false, send: nil, close: nil,
                    close_for_shutdown: nil)
  end
  let(:handlers) { {} }

  before do
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:connect) { connect_socket }
    allow($stdout).to receive(:puts)
  end

  after { @client&.shutdown }

  def connect_socket
    attempt = @attempts.shift
    raise attempt if attempt

    handlers.fetch(:open).call
    @reconnected&.push(true)
  end

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

    events = Queue.new
    @client.ticker_btc_jpy = ->(event) { events << event }
    @client.websocket_client.reconnect
    @client.executions_btc_jpy = ->(_event) {}
    ready = Queue.new
    @client.ready = -> { ready << true }
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('422["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events.pop(timeout: 5)).to eq({ 'ltp' => 100 })
    receive_message('431[null]')
    expect(ready).to be_empty
    receive_message('432[null]')
    expect(ready.pop(timeout: 5)).to be(true)
  end

  it 'stops delivering events from the current frame when a subscription callback shuts down' do
    @attempts = [nil]
    @client = Bitflyer.realtime_client
    events = []
    completed = Queue.new
    @client.ticker_btc_jpy = lambda do |event|
      events << event
      @client.shutdown
      completed << Thread.current
    end
    receive_message('0{}')

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100},{"ltp":101}]')

    worker = completed.pop(timeout: 5)
    expect(worker).to be_a(Thread)
    expect(worker.join(5)).to eq(worker)
    expect(events).to eq([{ 'ltp' => 100 }])
  end

  it 'delivers retained events in receive order across channels and drops new events when full' do
    stub_const("#{described_class}::CALLBACK_QUEUE_LIMIT", 2)
    @attempts = [nil]
    @client = Bitflyer.realtime_client
    release = Queue.new
    events = Queue.new
    @client.ticker_btc_jpy = lambda do |event|
      events << event
      release.pop if event.zero?
    end
    @client.executions_btc_jpy = ->(event) { events << event }

    receive_message('42["lightning_ticker_BTC_JPY",0]')
    expect(events.pop(timeout: 5)).to eq(0)
    receive_message('42["lightning_executions_BTC_JPY",1]')
    receive_message('42["lightning_ticker_BTC_JPY",2]')
    Timeout.timeout(5) { 10.times { receive_message('42["lightning_ticker_BTC_JPY",99]') } }
    release << true
    expect([events.pop(timeout: 5), events.pop(timeout: 5)]).to eq([1, 2])

    receive_message('42["lightning_ticker_BTC_JPY",3]')
    expect(events.pop(timeout: 5)).to eq(3)
  ensure
    release << true
  end

  it 'skips JSON serialization for market data dropped by a count-saturated callback queue' do
    stub_const("#{described_class}::CALLBACK_QUEUE_LIMIT", 1)
    @attempts = [nil]
    @client = Bitflyer.realtime_client
    allow(JSON).to receive(:generate).and_call_original
    release = Queue.new
    events = Queue.new
    @client.ticker_btc_jpy = lambda do |event|
      events << event
      release.pop
    end

    receive_message('42["lightning_ticker_BTC_JPY",0]')
    expect(events.pop(timeout: 5)).to eq(0)
    receive_message('42["lightning_ticker_BTC_JPY",1]')
    expect(JSON).to have_received(:generate).with(1, allow_nan: true)

    receive_message('42["lightning_ticker_BTC_JPY",2]')
    expect(JSON).not_to have_received(:generate).with(2, allow_nan: true)

    release << true
    expect(events.pop(timeout: 5)).to eq(1)
  ensure
    release << true
  end

  it 'waits for the replacement session before sending new subscriptions' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [nil, nil]
    @client = Bitflyer.realtime_client
    receive_message('0{}')

    allow(socket).to receive(:reconnectable?).and_return(true)
    @client.websocket_client.reconnect
    @client.ticker_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
  end

  def measure_retries(random:, ticks:)
    wakeup = ConditionVariable.new
    waiting = Queue.new
    delays = []
    now = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { now }
    allow(ConditionVariable).to receive(:new).and_return(wakeup)
    allow_any_instance_of(described_class).to receive(:rand).and_return(random)
    allow(wakeup).to receive(:wait).and_wrap_original do |wait, lock, delay|
      delays << delay
      if delays.size == ticks
        waiting << true
        wait.call(lock, delay)
      else
        now += (delay * 1000).to_i
      end
    end

    @client = Bitflyer.realtime_client
    allow(ConditionVariable).to receive(:new).and_call_original
    Timeout.timeout(5) { waiting.pop }
    Timeout.timeout(5) { @client.shutdown }
    delays
  end

  it 'increases retry delays to a cap and interrupts the capped wait on shutdown' do
    @attempts = Array.new(8) { Errno::ECONNREFUSED.new }

    expect(measure_retries(random: 0.5, ticks: 8)).to eq([0.75, 1.5, 3, 6, 12, 22.5, 22.5, 22.5])
    expect(socket).to have_received(:connect).exactly(8).times
  end

  it 'builds the TLS trust store once despite repeated connection refusals' do
    allow(Bitflyer::Realtime::Transport).to receive(:default_ssl_context).and_call_original
    @attempts = Array.new(8) { Errno::ECONNREFUSED.new }

    measure_retries(random: 0.5, ticks: 8)

    expect(socket).to have_received(:connect).exactly(8).times
    expect(Bitflyer::Realtime::Transport).to have_received(:default_ssl_context).once
  end

  it 'uses different retry delays across clients with different jitter samples' do
    delays = [0.25, 0.75].map do |random|
      @attempts = [Errno::ECONNREFUSED.new, Errno::ECONNREFUSED.new]
      measure_retries(random: random, ticks: 2)
    end

    expect(delays).to eq([[0.625, 1.25], [0.875, 1.75]])
  end

  it 'resets the delay when a session becomes ready before disconnecting' do
    @attempts = [Errno::ECONNREFUSED.new, Errno::ECONNREFUSED.new, nil, Errno::ECONNREFUSED.new]
    allow(socket).to receive(:connect) do
      connect_socket
      receive_message('0{}')
      allow(socket).to receive_messages(open?: false, closed?: true, reconnectable?: true)
      handlers.fetch(:close).call(nil)
    end

    expect(measure_retries(random: 0.5, ticks: 4)).to eq([0.75, 1.5, 0.75, 1.5])
    expect(socket).to have_received(:connect).exactly(4).times
  end

  it 'reaches session readiness after the network is down at startup' do
    @attempts = [Errno::ENETDOWN.new, nil]
    @reconnected = Queue.new
    ready = Queue.new

    @client = Bitflyer.realtime_client
    @client.ready = -> { ready << true }

    Timeout.timeout(5) { @reconnected.pop }
    receive_message('0{}')
    expect(ready.pop(timeout: 5)).to be(true)
    expect(socket).to have_received(:connect).twice
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, nil]
    @reconnected = Queue.new

    @client = Bitflyer.realtime_client

    Timeout.timeout(5) { @reconnected.pop }
    expect(socket).to have_received(:connect).exactly(3).times
    expect(@client.websocket_client.websocket_client).to eq(socket)
  end

  it 'keeps the monitor alive after reconnect errors outside the hardcoded whitelist' do
    @attempts = [SocketError.new('DNS lookup failed'), IOError.new('Connection failed'), nil]
    @reconnected = Queue.new

    @client = Bitflyer.realtime_client

    Timeout.timeout(5) { @reconnected.pop }
    expect(socket).to have_received(:connect).exactly(3).times
    expect(@client.websocket_client.websocket_client).to eq(socket)
  end

  it 'keeps the monitor alive after a broken WebSocket upgrade write and replays subscriptions once reconnected' do
    @attempts = [Errno::EPIPE.new, nil]
    @reconnected = Queue.new
    @client = Bitflyer.realtime_client
    events = Queue.new
    @client.ticker_btc_jpy = ->(event) { events << event }

    Timeout.timeout(5) { @reconnected.pop }
    expect(socket).to have_received(:connect).twice
    expect(socket).to have_received(:close_for_shutdown).once

    receive_message('0{}')
    expect(socket).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events.pop(timeout: 5)).to eq({ 'ltp' => 100 })
  end

  context 'when a session stalls before readiness' do
    let(:pongs) { Queue.new }
    let(:notifications) { Queue.new }
    let(:replacement) do
      instance_double(Bitflyer::Realtime::Transport, send: nil, close: nil, close_for_shutdown: nil,
                      open?: true, closed?: false, reconnectable?: false)
    end

    before do
      @attempts = [nil]
      @reconnected = Queue.new
      @session_time = 0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @session_time }
      allow(socket).to receive(:close) do
        allow(socket).to receive_messages(open?: false, closed?: true, reconnectable?: true)
        handlers.fetch(:close).call(nil)
      end
      replacement_handlers = {}
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)
      allow(replacement).to receive(:on) { |event, &handler| replacement_handlers[event] = handler }
      allow(replacement).to receive(:connect) do
        handlers.replace(replacement_handlers)
        handlers.fetch(:open).call
        @reconnected << true
      end
      allow(socket).to receive(:connect) { handlers.fetch(:open).call }
      [socket, replacement].each do |transport|
        allow(transport).to receive(:send).with('2') do
          receive_message('3')
          pongs << true
          true
        end
      end
    end

    it 'ignores a setup packet received at the deadline before the monitor runs' do
      allow_any_instance_of(described_class).to receive(:start_monitoring)
      @client = Bitflyer.realtime_client
      @client.ready = -> { notifications << :ready }
      @client.ticker_btc_jpy = ->(_event) {}
      @session_time = 10_000

      receive_message('0{}')

      expect(socket).not_to have_received(:send)
      expect(notifications).to be_empty
      expect(@client.websocket_client.send(:session_expired?, socket)).to be(true)
      expect(socket).to have_received(:close).once
    end

    { 'success' => '[null]', 'rejection' => '[{"message":"denied"}]' }.each do |result, response|
      it "ignores an authentication #{result} received at the deadline before the monitor runs" do
        allow_any_instance_of(described_class).to receive(:start_monitoring)
        @client = Bitflyer.realtime_client('key', 'secret')
        @client.ready = -> { notifications << :ready }
        @client.disconnected = ->(_error) { notifications << :disconnected }
        @client.child_order_events = ->(_event) {}
        @session_time = 9_000
        receive_message('0{}')
        @session_time = 19_000

        receive_message("430#{response}")

        expect(socket).not_to have_received(:send).with(start_with('421["subscribe",'))
        expect(notifications).to be_empty
        expect(@client.websocket_client.send(:session_expired?, socket)).to be(true)
        expect(socket).to have_received(:close).once
      end
    end

    it 'retries an open socket that never sends the Socket.IO setup packet' do
      @client = Bitflyer.realtime_client
      @client.ready = -> { notifications << :ready }
      @session_time = 10_000

      Timeout.timeout(5) { @reconnected.pop }
      expect(socket).to have_received(:close).once
      expect(socket).to have_received(:connect).once
      expect(replacement).to have_received(:connect).once
      expect(notifications).to be_empty

      receive_message('0{"pingInterval":1000}')
      expect(notifications.pop(timeout: 5)).to eq(:ready)
      @session_time += 10_000
      Timeout.timeout(5) { pongs.pop }
      expect(socket).to have_received(:close).once
      expect(replacement).not_to have_received(:close)
    end

    it 'retries when authentication stalls despite a current heartbeat' do
      @client = Bitflyer.realtime_client('key', 'secret')
      @client.ready = -> { notifications << :ready }
      @session_time = 9_000
      receive_message('0{"pingInterval":1000,"pingTimeout":1000}')

      @session_time = 10_000
      Timeout.timeout(5) { pongs.pop }
      @session_time = 18_000
      Timeout.timeout(5) { pongs.pop }
      receive_message('0{"pingInterval":1000,"pingTimeout":1000}')
      @session_time = 19_000
      Timeout.timeout(5) { @reconnected.pop }

      expect(socket).to have_received(:close).once
      expect(socket).to have_received(:connect).once
      expect(replacement).to have_received(:connect).once
      expect(notifications).to be_empty

      receive_message('0{"pingInterval":1000}')
      receive_message('430[null]')
      expect(notifications.pop(timeout: 5)).to eq(:ready)
      @session_time += 10_000
      Timeout.timeout(5) { pongs.pop }
      expect(socket).to have_received(:close).once
      expect(replacement).not_to have_received(:close)
    end
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

    notifications = Queue.new
    @client.ready = -> { notifications << :ready }
    expect(notifications).to be_empty
    receive_message('431[null]')
    expect(notifications.pop(timeout: 5)).to eq(:ready)
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
    errors = Queue.new
    notifications = []
    callback = ->(error) { errors << error }
    @client.disconnected = callback
    allow(socket).to receive(:close) do
      allow(socket).to receive_messages(open?: false, reconnectable?: true)
      handlers.fetch(:close).call(nil)
    end

    receive_message('0{}')
    receive_message('430[{"message":"Invalid API key"}]')
    @client.ready = -> { notifications << :ready }
    @client.disconnected = callback

    expect(@monitor.join(5)).to eq(@monitor)
    expect(socket).to have_received(:close).once
    expect(socket).not_to have_received(:send).with('421["subscribe","child_order_events"]')
    expect(socket).to have_received(:connect).twice
    expect(notifications).to be_empty
    expect(errors.pop(timeout: 5)&.message).to eq('Authentication failed: [{"message":"Invalid API key"}]')
    expect(errors).to be_empty
  end

  it 'delivers the original authentication error when a callback is registered after construction' do
    allow(socket).to receive(:connect) do
      handlers.fetch(:open).call
      receive_message('0{}')
      receive_message('430[{"message":"Invalid API key"}]')
    end
    @client = Bitflyer.realtime_client('key', 'secret')
    errors = []
    callback = ->(error) { errors << error }

    @client.ready = -> { raise 'Authentication rejection must not signal readiness' }
    @client.disconnected = nil
    @client.disconnected = callback
    @client.disconnected = callback

    expect(errors).to contain_exactly(an_instance_of(RuntimeError).and(
      have_attributes(message: 'Authentication failed: [{"message":"Invalid API key"}]')
    ))
  end

  it 'reports an exception from a late disconnected callback and consumes the pending error' do
    @attempts = [nil]
    @client = Bitflyer.realtime_client('key', 'secret')
    receive_message('0{}')
    receive_message('430[{"message":"Invalid API key"}]')

    expect do
      @client.disconnected = ->(_error) { raise 'late callback failed' }
    end.to output(/late callback failed/).to_stderr
    callback = spy('replacement disconnected callback')
    @client.disconnected = callback
    expect(callback).not_to have_received(:call)
  end

  it 'delivers an authentication error once when registration overlaps rejection' do
    @attempts = [nil]
    @client = Bitflyer.realtime_client('key', 'secret')
    receive_message('0{}')
    closing = Queue.new
    finish_close = Queue.new
    allow(socket).to receive(:close) do
      closing << true
      finish_close.pop
      handlers.fetch(:close).call(nil)
    end
    errors = Queue.new
    callback = ->(error) { errors << error }
    rejection = Thread.new { receive_message('430[{"message":"Invalid API key"}]') }

    begin
      Timeout.timeout(5) { closing.pop }
      @client.disconnected = callback
    ensure
      finish_close << true
      rejection.join
      allow(socket).to receive(:close).and_return(nil)
    end
    @client.disconnected = callback

    expect(errors.pop(timeout: 5)&.message).to eq('Authentication failed: [{"message":"Invalid API key"}]')
    expect(errors).to be_empty
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'when replacing a socket' do
  let(:original_socket) { instance_double(Bitflyer::Realtime::Transport, reconnectable?: false) }
  let(:replacement_socket) { instance_double(Bitflyer::Realtime::Transport) }
  let(:message_handlers) { {} }

  before do
    [original_socket, replacement_socket].each do |socket|
      allow(socket).to receive_messages(connect: nil, send: true)
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

    @heartbeat_time += 1_000
    client.send_ping
    @heartbeat_time += 1_000
    expect(original_socket).to receive(:close)
    client.wait_pong

    allow(original_socket).to receive(:reconnectable?).and_return(true)
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
    allow(original_socket).to receive(:reconnectable?).and_return(true)
    client.reconnect
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    message_handlers.fetch(replacement_socket).call(setup)

    @heartbeat_time += 1_000
    client.send_ping
    @heartbeat_time += 1_000
    expect(replacement_socket).to receive(:close)
    client.wait_pong
  end

  it 'keeps the replacement heartbeat deadline when an old pong is already being dispatched' do
    allow(Time).to receive(:now) { Time.at(@heartbeat_time / 1_000) }
    allow(replacement_socket).to receive(:close)
    client = described_class.new(host: 'wss://example.test', key: nil, secret: nil)
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    payload = double('pong frame')
    allow(payload).to receive(:data) do
      allow(original_socket).to receive(:reconnectable?).and_return(true)
      client.reconnect
      message_handlers.fetch(replacement_socket).call(setup)
      @heartbeat_time += 1_000
      client.send_ping
      '3'
    end

    message_handlers.fetch(original_socket).call(payload)

    expect(client.last_pong_at).to eq(10)
    @heartbeat_time += 999
    client.wait_pong
    expect(replacement_socket).not_to have_received(:close)

    @heartbeat_time += 1
    client.wait_pong
    expect(replacement_socket).to have_received(:close).once
  end
end

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  subject(:client) { described_class.new(host: 'wss://example.test', key: key, secret: secret) }

  let(:socket) { instance_double(Bitflyer::Realtime::Transport, on: nil, send: true, close: nil, connect: nil, open?: true) }
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

  it 'sends a ping at each elapsed interval after the previous pong' do
    @wall_time += 60
    @heartbeat_time += 1_499
    client.send_ping
    expect(socket).not_to have_received(:send)

    @wall_time -= 160
    @heartbeat_time += 1
    client.send_ping
    client.send_ping
    expect(socket).to have_received(:send).with('2').once

    client.receive_pong
    @heartbeat_time += 1_500
    client.send_ping
    expect(socket).to have_received(:send).with('2').twice
  end

  it 'gives a delayed monitor ping the full timeout despite wall-clock changes' do
    @wall_time += 60
    @heartbeat_time += 2_250
    client.__send__(:poll_transport)
    expect(socket).to have_received(:send).with('2').once
    expect(socket).not_to have_received(:close)

    @wall_time -= 160
    @heartbeat_time += 749
    client.__send__(:poll_transport)
    expect(socket).not_to have_received(:close)

    @heartbeat_time += 1
    client.__send__(:poll_transport)
    expect(socket).to have_received(:close).once
  end

  it 'keeps the connection open when a delayed ping receives its pong before the deadline' do
    @heartbeat_time += 2_250
    client.__send__(:poll_transport)
    @heartbeat_time += 749
    @wall_time += 1
    client.handle_message(payload: Struct.new(:data).new('3'), socket: socket)
    expect(client.last_pong_at).to eq(1_001)

    @heartbeat_time += 1
    client.__send__(:poll_transport)
    expect(socket).not_to have_received(:close)
    expect(socket).to have_received(:send).with('2').once
  end

  it 'does not start a pong timeout when a ping write fails' do
    allow(socket).to receive(:send).with('2').and_return(false)
    @heartbeat_time += 1_500
    client.send_ping

    @heartbeat_time += 750
    client.wait_pong
    expect(socket).not_to have_received(:close)
    expect(client.last_ping_at).to eq(1_000)
  end

  it 'accepts a pong dispatched before the ping write returns' do
    allow(socket).to receive(:send).with('2') do
      client.receive_pong
      true
    end
    @heartbeat_time += 1_500
    client.send_ping

    @heartbeat_time += 750
    client.wait_pong
    expect(socket).not_to have_received(:close)
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

  it 'uses a Unix-second ping timestamp write when scheduling the next ping' do
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

  it 'does not send a ping when the last ping timestamp is set to nil' do
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
  let(:transport) do
    instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, reconnectable?: false,
                    close_for_shutdown: nil)
  end
  let(:handlers) { {} }
  let(:ready_notifications) { Queue.new }
  let(:failure_notifications) { Queue.new }
  let(:ready) do
    spy('ready callback').tap { |callback| allow(callback).to receive(:call) { ready_notifications << true } }
  end
  let(:subscription_failed) do
    spy('subscription failure callback').tap do |callback|
      allow(callback).to receive(:call) { |*args| failure_notifications << args }
    end
  end
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
    allow(socket).to receive(:close_for_shutdown)
  end

  def receive_frame(frame, events = handlers)
    events.fetch(:message).call(double(data: frame))
  end

  def realtime_client
    @client = Bitflyer.realtime_client(key, secret).tap do |client|
      client.ready = ready
      client.subscription_failed = subscription_failed
    end
  end

  after { @client&.shutdown }

  [10_000, 10_001].each do |elapsed|
    it "closes on a setup acknowledgment at #{elapsed} ms before polling and becomes ready after replay" do
      now = 100_000
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { now }
      @client = Bitflyer.realtime_client
      @client.ticker_btc_jpy = ->(_message) {}
      @client.executions_btc_jpy = ->(_message) {}
      receive_frame('0{}')
      receive_frame('431[null]')

      replacement = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false)
      replacement_handlers = {}
      stub_transport(replacement, replacement_handlers)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
      expect(transport).to receive(:close) do
        allow(transport).to receive(:closed?).and_return(true)
        handlers.fetch(:close).call(nil)
        allow(transport).to receive(:reconnectable?).and_return(true)
      end

      now += elapsed
      receive_frame('432[null]')
      @client.ready = ready
      expect(ready).not_to have_received(:call)

      @client.websocket_client.reconnect
      receive_frame('0{}', replacement_handlers)
      expect(replacement).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
      expect(replacement).to have_received(:send).with('422["subscribe","lightning_executions_BTC_JPY"]').once

      now += 9_999
      receive_frame('431[null]', replacement_handlers)
      expect(ready).not_to have_received(:call)
      receive_frame('432[null]', replacement_handlers)
      receive_frame('432[null]', replacement_handlers)
      expect(ready_notifications.pop(timeout: 5)).to be(true)
      expect(ready).to have_received(:call).once
    end
  end

  shared_examples 'a stalled setup subscription' do
    it 'reconnects despite fresh pongs and notifies readiness once after replay' do
      now = 100_000
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { now }
      client = realtime_client
      websocket = client.websocket_client
      client.ticker_btc_jpy = ->(_message) {}
      client.executions_btc_jpy = ->(_message) {}
      receive_frame('0{"pingInterval":1000,"pingTimeout":2000}')
      receive_frame('430[null]') if key
      receive_frame('431[null]')

      replacement = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false)
      replacement_handlers = {}
      stub_transport(replacement, replacement_handlers)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
      allow(transport).to receive(:open?) { !transport.closed? }
      allow(transport).to receive(:send).with('2') do
        receive_frame('3')
        true
      end
      expect(transport).to receive(:close) do
        expect(now).to eq(110_000)
        receive_frame('432[null]')
        allow(transport).to receive(:closed?).and_return(true)
        handlers.fetch(:close).call(nil)
        allow(transport).to receive(:reconnectable?).and_return(true)
      end

      ticks = [109_999, 110_000, 111_000]
      allow(websocket.instance_variable_get(:@monitor_wakeup)).to receive(:wait) { now = ticks.shift }
      allow(websocket).to receive(:wait_for_monitor_tick).and_wrap_original do |wait|
        wait.call unless ticks.empty?
      end
      allow(websocket).to receive(:start_monitoring).and_call_original
      expect(websocket.send(:start_monitoring).join(5)).to be_a(Thread)
      expect(transport).to have_received(:send).with('2').once
      expect(websocket.websocket_client).to equal(replacement)
      expect(ready).not_to have_received(:call)

      receive_frame('0{}', replacement_handlers)
      receive_frame('430[null]', replacement_handlers) if key
      expect(replacement).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
      expect(replacement).to have_received(:send).with('422["subscribe","lightning_executions_BTC_JPY"]').once
      receive_frame('432[null]', replacement_handlers)
      expect(ready).not_to have_received(:call)
      receive_frame('431[null]', replacement_handlers)
      receive_frame('431[null]', replacement_handlers)
      expect(ready_notifications.pop(timeout: 5)).to be(true)
      expect(ready).to have_received(:call).once
    end
  end

  include_examples 'a stalled setup subscription'

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
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once
  end

  it 'handles runtime acknowledgments without scanning pending IDs before or after ready registration' do
    client = @client = Bitflyer.realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    receive_frame('431[null]')

    10.times { |index| client.subscribe("runtime_#{index}") { |_message| } }
    pending = client.websocket_client.instance_variable_get(:@pending_subscriptions)
    expect(pending).not_to receive(:each_key)

    (2..6).each { |id| receive_frame("43#{id}[null]") }
    client.ready = ready
    expect(ready).to have_received(:call).once

    (7..11).each { |id| receive_frame("43#{id}[null]") }
    expect(pending).to be_empty
    expect(ready).to have_received(:call).once
  end

  it 'replaces a pending subscription callback without sending another request' do
    client = realtime_client
    original_callback = spy('original callback')
    events = Queue.new
    client.ticker_btc_jpy = ->(message) { original_callback.call(message) }
    receive_frame('0{}')

    client.ticker_btc_jpy = ->(message) { events << message }
    expect(transport).to have_received(:send).with(/"subscribe","lightning_ticker_BTC_JPY"/).once

    receive_frame('431[null]')
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    receive_frame('42["lightning_ticker_BTC_JPY",1]')
    expect(events.pop(timeout: 5)).to eq(1)
    expect(original_callback).not_to have_received(:call)
  end

  it 'exposes frozen channel snapshots and sends changes through the subscription methods' do
    client = realtime_client
    websocket = client.websocket_client
    channel = :lightning_ticker_BTC_JPY
    callback = ->(_message) {}
    expect(websocket).not_to respond_to(:channel_names=)
    expect(websocket).not_to respond_to(:channel_callbacks=)

    client.ticker_btc_jpy = callback
    names = websocket.channel_names
    callbacks = websocket.channel_callbacks
    expect(names).to eq([channel]).and be_frozen
    expect(callbacks).to eq(channel => callback).and be_frozen
    expect { names << :another }.to raise_error(FrozenError)
    expect { callbacks.delete(channel) }.to raise_error(FrozenError)

    receive_frame('0{}')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').once
    client.unsubscribe(channel)
    expect(transport).to have_received(:send).with('42["unsubscribe","lightning_ticker_BTC_JPY"]').once
    expect(websocket.channel_names).to be_empty
    expect(websocket.channel_callbacks).to be_empty
    expect(names).to eq([channel])
    expect(callbacks).to eq(channel => callback)
  end

  it 'keeps order book channels registered after removing a user callback' do
    client = realtime_client
    websocket = client.websocket_client
    client.order_book(product_code: 'BTC_JPY')
    client.board_btc_jpy = ->(_message) {}
    client.unsubscribe(:lightning_board_BTC_JPY)

    expect(websocket.channel_names).to eq(%i[lightning_board_BTC_JPY lightning_board_snapshot_BTC_JPY])
    expect(websocket.channel_callbacks).to be_empty
    receive_frame('0{}')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_board_BTC_JPY"]').once
    expect(transport).to have_received(:send).with('422["subscribe","lightning_board_snapshot_BTC_JPY"]').once
  end

  it 'unsubscribes one runtime channel while retaining the others across reconnect' do
    client = @client = Bitflyer.realtime_client('key', 'secret')
    client.ready = ready
    events = Queue.new
    client.child_order_events = ->(message) { events << [:order, message] }
    receive_frame('0{}')
    receive_frame('430[null]')
    receive_frame('431[null]')
    expect(ready_notifications.pop(timeout: 5)).to be(true)

    client.subscribe('lightning_ticker_SOL_JPY') { |message| events << [:ticker, message] }
    expect(transport).to have_received(:send).with('422["subscribe","lightning_ticker_SOL_JPY"]').once
    receive_frame('432[null]')
    receive_frame('42["lightning_ticker_SOL_JPY",1]')
    expect(events.pop(timeout: 5)).to eq([:ticker, 1])

    client.unsubscribe(:lightning_ticker_SOL_JPY)
    client.unsubscribe('lightning_ticker_SOL_JPY')
    expect(transport).to have_received(:send).with('42["unsubscribe","lightning_ticker_SOL_JPY"]').once
    receive_frame('42["lightning_ticker_SOL_JPY",2]')
    receive_frame('42["child_order_events",3]')
    expect(events.pop(timeout: 5)).to eq([:order, 3])

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(transport).to receive(:reconnectable?).and_return(true)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)
    client.websocket_client.reconnect
    receive_frame('42["child_order_events","before setup"]', next_handlers)
    receive_frame('0{}', next_handlers)
    receive_frame('42["child_order_events","before authentication"]', next_handlers)
    receive_frame('430[null]', next_handlers)
    client.websocket_client.handle_message(payload: double(data: '431[null]'), socket: transport)
    receive_frame('42["child_order_events","before acknowledgment"]', next_handlers)
    receive_frame('431[null]', next_handlers)
    receive_frame('42["child_order_events",4]', next_handlers)

    expect(next_transport).to have_received(:send).with('421["subscribe","child_order_events"]')
    expect(next_transport).to have_received(:send).exactly(2).times
    expect(events.pop(timeout: 5)).to eq([:order, 4])
    expect(ready).to have_received(:call).twice
  end

  it 'ignores a canceled setup acknowledgment and reports a runtime rejection once' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')

    client.unsubscribe('lightning_ticker_BTC_JPY')
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once
    client.subscribe('lightning_ticker_BTC_JPY') { |_message| }
    expect(transport).to have_received(:send).with('422["subscribe","lightning_ticker_BTC_JPY"]')

    receive_frame('431["stale rejection"]')
    receive_frame('432["rejected"]')
    receive_frame('432["rejected"]')
    expect(failure_notifications.pop(timeout: 5)).to eq([:lightning_ticker_BTC_JPY, 'rejected'])
    expect(subscription_failed).to have_received(:call).once
    expect(ready).to have_received(:call).once

    client.ticker_btc_jpy = ->(_message) {}
    expect(transport).to have_received(:send).with('423["subscribe","lightning_ticker_BTC_JPY"]').once
  end

  it 'keeps the connection open when only a runtime subscription is pending at the setup deadline' do
    now = 100_000
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { now }
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    now += 1_000
    client.subscribe('lightning_executions_BTC_JPY') { |_message| }
    receive_frame('431[null]')

    now = 110_000
    expect(transport).not_to receive(:close)
    client.websocket_client.send(:close_expired_subscriptions)
    receive_frame('432["rejected"]')

    expect(failure_notifications.pop(timeout: 5)).to eq([:lightning_executions_BTC_JPY, 'rejected'])
    expect(ready).to have_received(:call).once
  end

  context 'with runtime subscription deadlines' do
    let(:client) { realtime_client }
    let(:events) { Queue.new }
    let(:websocket) { client.websocket_client }
    let(:writer) { websocket.instance_variable_get(:@subscription_writer) }

    before do
      @now = 100_000
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @now }
      allow(transport).to receive(:open?).and_return(true)
      allow(transport).to receive(:send).with('2') do
        receive_frame('3')
        true
      end
      client.executions_btc_jpy = ->(message) { events << message }
      receive_frame('0{"pingInterval":1000,"pingTimeout":2000}')
      receive_frame('431[null]')
      expect(ready_notifications.pop(timeout: 5)).to be(true)
    end

    def poll_after(milliseconds)
      @now += milliseconds
      websocket.send(:poll_transport)
    end

    it 'gives a queued subscription the full acknowledgment window after dispatch' do
      frame = '422["subscribe","lightning_ticker_BTC_JPY"]'
      writer.synchronize do
        client.ticker_btc_jpy = ->(_message) {}
        11.times { poll_after(1_000) }
        expect(transport).not_to have_received(:send).with(frame)
      end

      websocket.send(:send_subscription_frames)
      expect(transport).to have_received(:send).with(frame).once
      9.times { poll_after(1_000) }
      poll_after(999)
      expect(failure_notifications).to be_empty

      poll_after(1)
      expect(failure_notifications.pop(timeout: 5))
        .to eq([:lightning_ticker_BTC_JPY, 'Timed out waiting for subscription acknowledgment'])
      2.times { poll_after(1_000) }
      receive_frame('432["late rejection"]')
      receive_frame('42["lightning_executions_BTC_JPY",1]')
      expect(events.pop(timeout: 5)).to eq(1)
      expect(subscription_failed).to have_received(:call).once
    end

    it 'skips a canceled queued request even when the same channel is registered again' do
      writer.synchronize do
        client.ticker_btc_jpy = ->(_message) {}
        client.unsubscribe('lightning_ticker_BTC_JPY')
        client.ticker_btc_jpy = ->(message) { events << message }
      end

      websocket.send(:send_subscription_frames)
      expect(transport).not_to have_received(:send).with('422["subscribe","lightning_ticker_BTC_JPY"]')
      expect(transport).to have_received(:send).with('423["subscribe","lightning_ticker_BTC_JPY"]').once
      receive_frame('433[null]')
      receive_frame('42["lightning_ticker_BTC_JPY",1]')
      expect(events.pop(timeout: 5)).to eq(1)
      expect(subscription_failed).not_to have_received(:call)
    end

    it 'leaves no queued frames after repeated subscribe and unsubscribe pairs while dispatch is stalled' do
      writer.synchronize do
        100.times do
          client.ticker_btc_jpy = ->(_message) {}
          client.unsubscribe('lightning_ticker_BTC_JPY')
        end
      end

      expect(websocket.instance_variable_get(:@subscription_frames)).to be_empty
      expect(websocket.instance_variable_get(:@pending_subscriptions)).to be_empty
      expect(websocket.instance_variable_get(:@pending_subscription_ids)).to be_empty
      expect(websocket.channel_names).to eq([:lightning_executions_BTC_JPY])
      expect(transport).not_to have_received(:send).with(/"unsubscribe"/)
    end

    it 'expires each missing acknowledgment on its own deadline while pongs and other events continue' do
      client.subscribe('lightning_ticker_BTC_JPY') { |_message| }
      5.times { poll_after(1_000) }
      client.subscribe('lightning_ticker_SOL_JPY') { |_message| }
      4.times { poll_after(1_000) }
      expect(subscription_failed).not_to have_received(:call)

      poll_after(1_000)
      expect(failure_notifications.pop(timeout: 5))
        .to eq([:lightning_ticker_BTC_JPY, 'Timed out waiting for subscription acknowledgment'])
      expect(subscription_failed).to have_received(:call).once
      receive_frame('432["late rejection"]')
      receive_frame('42["lightning_executions_BTC_JPY",1]')
      expect(events.pop(timeout: 5)).to eq(1)

      5.times { poll_after(1_000) }
      expect(failure_notifications.pop(timeout: 5))
        .to eq([:lightning_ticker_SOL_JPY, 'Timed out waiting for subscription acknowledgment'])
      expect(subscription_failed).to have_received(:call).twice
      expect(transport).to have_received(:send).with('2').exactly(15).times
      expect(ready).to have_received(:call).once
    end

    it 'resubscribes a timed-out channel with a fresh acknowledgment ID' do
      client.ticker_btc_jpy = ->(_message) {}
      10.times { poll_after(1_000) }
      expect(failure_notifications.pop(timeout: 5))
        .to eq([:lightning_ticker_BTC_JPY, 'Timed out waiting for subscription acknowledgment'])

      client.ticker_btc_jpy = ->(message) { events << message }
      expect(transport).to have_received(:send).with('423["subscribe","lightning_ticker_BTC_JPY"]').once
      receive_frame('432["late rejection"]')
      receive_frame('433[null]')
      receive_frame('42["lightning_ticker_BTC_JPY",1]')
      expect(events.pop(timeout: 5)).to eq(1)
      expect(subscription_failed).to have_received(:call).once
    end

    it 'continues polling and reconnects while a timeout handler blocks, discarding queued failures on close' do
      replacement = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, close_for_shutdown: nil)
      replacement_handlers = {}
      stub_transport(replacement, replacement_handlers)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
      release = Queue.new
      client.subscription_failed = lambda do |channel, _error|
        failure_notifications << channel
        release.pop
      end
      client.subscribe('lightning_ticker_BTC_JPY') { |_message| }
      client.subscribe('lightning_ticker_SOL_JPY') { |_message| }

      poll = Thread.new { poll_after(10_000) }
      expect(failure_notifications.pop(timeout: 5)).to eq(:lightning_ticker_BTC_JPY)
      expect(poll.join(5)).to eq(poll)
      poll_after(1_000)
      expect(transport).to have_received(:send).with('2').twice

      handlers.fetch(:close).call(nil)
      allow(transport).to receive(:reconnectable?).and_return(true)
      client.websocket_client.reconnect
      receive_frame('0{}', replacement_handlers)
      %w[431 432 433].each { |id| receive_frame("#{id}[null]", replacement_handlers) }
      receive_frame('42["lightning_executions_BTC_JPY",2]', replacement_handlers)
      release.close

      expect(events.pop(timeout: 5)).to eq(2)
      expect(failure_notifications).to be_empty
    ensure
      release&.close
      poll&.join(5)
    end

    it 'clears deadlines for acknowledged and unsubscribed requests' do
      client.subscribe('lightning_ticker_BTC_JPY') { |_message| }
      client.subscribe('lightning_ticker_SOL_JPY') { |_message| }
      receive_frame('432[null]')
      receive_frame('432["duplicate rejection"]')
      client.unsubscribe('lightning_ticker_SOL_JPY')
      receive_frame('433["late rejection"]')

      11.times { poll_after(1_000) }
      receive_frame('42["lightning_executions_BTC_JPY",1]')
      expect(events.pop(timeout: 5)).to eq(1)
      expect(subscription_failed).not_to have_received(:call)
    end
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
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once
  end

  it 'delivers events after resubscribing a channel unsubscribed while its subscribe frame was dispatching' do
    client = realtime_client
    events = Queue.new
    client.ticker_btc_jpy = ->(_message) {}
    subscribe_frame = '421["subscribe","lightning_ticker_BTC_JPY"]'
    unsubscribe_frame = '42["unsubscribe","lightning_ticker_BTC_JPY"]'
    resubscribe_frame = '422["subscribe","lightning_ticker_BTC_JPY"]'
    frames = []
    allow(transport).to receive(:send) do |frame|
      if frame == subscribe_frame
        client.unsubscribe('lightning_ticker_BTC_JPY')
        client.ticker_btc_jpy = ->(message) { events << message }
      end
      frames << frame
    end

    receive_frame('0{}')

    expect(frames).to eq([subscribe_frame, unsubscribe_frame, resubscribe_frame])
    receive_frame('432[null]')
    receive_frame('42["lightning_ticker_BTC_JPY",1]')
    expect(events.pop(timeout: 5)).to eq(1)
  end

  it 'queues readiness behind a running market-data callback when the last pending channel is removed' do
    client = realtime_client
    started = Queue.new
    resume = Queue.new
    events = Queue.new
    allow(ready).to receive(:call) { events << [:ready, Thread.current] }
    client.ticker_btc_jpy = lambda do |message|
      started << Thread.current
      resume.pop
      events << message
    end
    client.executions_btc_jpy = ->(_message) {}

    receive_frame('0{}')
    receive_frame('431[null]')
    receive_frame('42["lightning_ticker_BTC_JPY","ticker"]')
    worker = started.pop(timeout: 5)
    expect(worker).to be_a(Thread)

    unsubscribe = Thread.new { client.unsubscribe('lightning_executions_BTC_JPY') }
    expect(unsubscribe.join(5)).to eq(unsubscribe)
    expect(ready).not_to have_received(:call)
    receive_frame('432[null]')
    resume.close

    expect(events.pop(timeout: 5)).to eq('ticker')
    expect(events.pop(timeout: 5)).to eq([:ready, worker])
    expect(ready).to have_received(:call).once
  ensure
    resume&.close
    unsubscribe&.join(5)
    client&.shutdown
  end

  it 'delivers readiness synchronously when registered after removing the last pending channel' do
    client = @client = Bitflyer.realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    client.unsubscribe('lightning_ticker_BTC_JPY')

    callers = []
    callback = -> { callers << Thread.current }
    2.times { client.ready = callback }

    expect(callers).to eq([Thread.current])
  end

  it 'waits for new acknowledgments after reconnecting and ignores replies from the previous socket' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')
    receive_frame('431[null]')
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, close_for_shutdown: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)

    allow(transport).to receive(:reconnectable?).and_return(true)
    handlers.fetch(:close).call(nil)
    client.websocket_client.reconnect
    receive_frame('0{}', next_handlers)
    receive_frame('431[null]')
    expect(ready).to have_received(:call).once

    receive_frame('431[null]', next_handlers)
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).twice
  end

  it 'discards a full queue of deltas on disconnect and delivers replacement deltas in order' do
    stub_const("#{described_class}::CALLBACK_PAYLOAD_LIMIT", 1_024 * '"stale"'.bytesize)
    client = realtime_client
    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, close_for_shutdown: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)
    started = Queue.new
    resume = Queue.new
    events = Queue.new
    client.ready = -> { events << 'ready' }
    client.board_btc_jpy = lambda do |delta|
      if delta == 'running'
        started << true
        resume.pop
      end
      events << delta
    end
    receive_frame('0{}')
    receive_frame('431[null]')
    expect(events.pop(timeout: 5)).to eq('ready')
    receive_frame('42["lightning_board_BTC_JPY","running"]')
    expect(started.pop(timeout: 5)).to be(true)
    receive_frame("42#{JSON.generate(['lightning_board_BTC_JPY', *Array.new(1_024, 'stale')])}")

    handlers.fetch(:close).call(nil)
    expect(client.websocket_client.instance_variable_get(:@pending_callback_bytes)).to eq(0)
    allow(transport).to receive(:reconnectable?).and_return(true)
    client.websocket_client.reconnect
    receive_frame('0{}', next_handlers)
    receive_frame('431[null]', next_handlers)
    receive_frame('42["lightning_board_BTC_JPY","first","second"]', next_handlers)
    resume << true

    expect(Array.new(4) { events.pop(timeout: 5) }).to eq(%w[running ready first second])
  ensure
    resume&.close
    client&.shutdown
  end

  it 'rejects deltas routed before close but enqueued after close or replacement' do
    client = realtime_client
    websocket = client.websocket_client
    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, close_for_shutdown: nil)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)
    events = Queue.new
    resume = Queue.new
    allow(websocket).to receive(:deliver_callbacks).and_wrap_original do |deliver|
      resume.pop
      deliver.call
    end
    client.board_btc_jpy = ->(delta) { events << delta }
    receive_frame('0{}')
    receive_frame('431[null]')
    allow(websocket).to receive(:route_messages).and_wrap_original do |route, channel, messages, socket, &enqueue|
      route.call(channel, messages, socket) do |token|
        if socket.equal?(transport)
          handlers.fetch(:close).call(nil)
          enqueue.call(token)
          allow(transport).to receive(:reconnectable?).and_return(true)
          websocket.reconnect
        end
        enqueue.call(token)
      end
    end

    receive_frame("42#{JSON.generate(['lightning_board_BTC_JPY', *Array.new(1_024, 'stale')])}")
    receive_frame('0{}', next_handlers)
    receive_frame('431[null]', next_handlers)
    receive_frame('42["lightning_board_BTC_JPY","fresh"]', next_handlers)
    resume << true

    expect(events.pop(timeout: 5)).to eq('fresh')
  ensure
    resume&.close
    client&.shutdown
  end

  it 'ignores an acknowledgment that was being read when the socket was replaced' do
    client = realtime_client
    client.ticker_btc_jpy = ->(_message) {}
    receive_frame('0{}')

    next_transport = instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false)
    next_handlers = {}
    stub_transport(next_transport, next_handlers)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(next_transport)

    payload = double('old acknowledgment')
    allow(payload).to receive(:data) do
      allow(transport).to receive(:reconnectable?).and_return(true)
      client.websocket_client.reconnect
      receive_frame('0{}', next_handlers)
      '431[null]'
    end
    handlers.fetch(:message).call(payload)

    expect(next_transport).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]')
    expect(ready).not_to have_received(:call)

    receive_frame('431[null]', next_handlers)
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once
  end

  it 'leaves the replacement open when reading a disconnect frame from the previous socket' do
    websocket = realtime_client.websocket_client
    replacement = instance_double(Bitflyer::Realtime::Transport, close: nil)
    stub_transport(replacement, {})
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
    allow(transport).to receive(:close)

    payload = double('buffered disconnect frame')
    allow(payload).to receive(:data) do
      allow(transport).to receive_messages(closed?: true, reconnectable?: true)
      handlers.fetch(:close).call(nil)
      websocket.reconnect
      '41'
    end
    handlers.fetch(:message).call(payload)

    expect(websocket.websocket_client).to equal(replacement)
    expect(replacement).not_to have_received(:close)
  end

  it 'closes the active socket on a disconnect frame and reconnects' do
    websocket = realtime_client.websocket_client
    replacement = instance_double(Bitflyer::Realtime::Transport)
    stub_transport(replacement, {})
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
    allow(transport).to receive(:close) do
      allow(transport).to receive_messages(closed?: true, reconnectable?: true)
      handlers.fetch(:close).call(nil)
    end

    receive_frame('41')

    expect(transport).to have_received(:close).once
    websocket.reconnect
    expect(websocket.websocket_client).to equal(replacement)
  end

  it 'signals readiness on setup when there are no subscriptions' do
    realtime_client
    receive_frame('0{}')
    expect(ready_notifications.pop(timeout: 5)).to be(true)
    expect(ready).to have_received(:call).once
  end

  it 'bounds pending failures independently of market data while processing acknowledgments and pongs' do
    client = realtime_client
    websocket = client.websocket_client
    resume = Queue.new
    failures = Queue.new
    ticks = Queue.new
    client.subscription_failed = lambda do |_channel, error|
      failures << error
      resume.pop if error == 'first'
    end
    receive_frame('0{}')
    client.ticker_btc_jpy = ->(message) { ticks << message }
    receive_frame('431[null]')
    client.executions_btc_jpy = ->(_message) {}
    receive_frame('432["first"]')
    expect(failures.pop(timeout: 5)).to eq('first')

    limit = described_class.const_get(:FAILURE_NOTIFICATION_QUEUE_LIMIT)
    market_limit = described_class.const_get(:CALLBACK_QUEUE_LIMIT)
    websocket.last_pong_at = 0
    reader = Thread.new do
      (limit + 2).times do |index|
        client.executions_btc_jpy = ->(_message) {}
        receive_frame("43#{index + 3}#{[index].to_json}")
      end
      receive_frame('3')
      receive_frame("42#{['lightning_ticker_BTC_JPY', *(0..market_limit)].to_json}")
    end
    expect(reader.join(5)).to eq(reader)
    expect(transport).to have_received(:send).with("42#{limit + 4}#{%w[subscribe lightning_executions_BTC_JPY].to_json}")
    expect(websocket.last_pong_at).to be_positive

    resume.close
    delivered = Array.new(market_limit) { ticks.pop(timeout: 5) || break }
    expect(delivered).to eq((0...market_limit).to_a)
    expect(Array.new(failures.size) { failures.pop }).to eq((0...limit).to_a)

    client.executions_btc_jpy = ->(_message) {}
    receive_frame("43#{limit + 5}#{['after drain'].to_json}")
    expect(failures.pop(timeout: 5)).to eq('after drain')
    expect(ticks).to be_empty
  ensure
    resume&.close
    reader&.join(5)
  end

  { ready: '431[null]', subscription_failed: '431["denied"]' }.each do |notification, acknowledgment|
    it "processes a pong while the #{notification} callback is blocked" do
      client = realtime_client
      websocket = client.websocket_client
      started = Queue.new
      resume = Queue.new
      client.public_send("#{notification}=", ->(*_args) { started << true; resume.pop })
      client.ticker_btc_jpy = ->(_message) {}
      receive_frame('0{}')
      websocket.last_pong_at = 0

      reader = Thread.new do
        receive_frame(acknowledgment)
        receive_frame('3')
      end

      expect(started.pop(timeout: 5)).to be(true)
      expect(reader.join(5)).to eq(reader)
      expect(websocket.last_pong_at).to be_positive
    ensure
      resume&.close
      reader&.join(5)
    end
  end

  context 'with credentials' do
    let(:key) { 'key' }
    let(:secret) { 'secret' }

    include_examples 'a stalled setup subscription'

    it 'waits for the private subscription after authentication' do
      client = realtime_client
      events = Queue.new
      client.child_order_events = ->(message) { events << message }

      receive_frame('42["child_order_events","before setup"]')
      receive_frame('0{}')
      receive_frame('42["child_order_events","before authentication"]')
      expect(transport).to have_received(:send).with(start_with('420["auth",'))
      expect(transport).not_to have_received(:send).with('421["subscribe","child_order_events"]')

      receive_frame('430[ null ]')
      receive_frame('431{}')
      receive_frame('42["child_order_events","before acknowledgment"]')
      expect(transport).to have_received(:send).with('421["subscribe","child_order_events"]')
      expect(ready).not_to have_received(:call)

      receive_frame("431[\n  null\n]")
      receive_frame('42["child_order_events","acknowledged"]')
      expect(events.pop(timeout: 5)).to eq('acknowledged')
      expect(ready_notifications.pop(timeout: 5)).to be(true)
      expect(ready).to have_received(:call).once

      receive_frame('430[null]')
      receive_frame('431[null]')
      expect(ready).to have_received(:call).once
    end

    it 'reports a false subscription error and keeps ready pending after the other subscription succeeds' do
      client = realtime_client
      events = Queue.new
      client.child_order_events = ->(message) { events << message }
      client.ticker_btc_jpy = ->(message) { events << message }

      receive_frame('0{}')
      receive_frame('430[null]')
      receive_frame('431[false]')
      receive_frame('431[false]')
      receive_frame('432[null]')
      receive_frame('42["child_order_events","rejected"]')
      receive_frame('42["lightning_ticker_BTC_JPY",1]')

      expect(events.pop(timeout: 5)).to eq(1)
      expect(failure_notifications.pop(timeout: 5)).to eq([:child_order_events, false])
      expect(subscription_failed).to have_received(:call).once
      expect(ready).not_to have_received(:call)
    end
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'packet handling' do
  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, on: nil, send: nil, close: nil, connect: nil, open?: true, closed?: false,
                    close_for_shutdown: nil)
  end
  let(:host) { 'wss://example.test' }
  let(:key) { nil }
  let(:secret) { nil }
  let(:client) { described_class.new(host: host, key: key, secret: secret) }
  let(:ready_notifications) { Queue.new }
  let(:ready) { -> { ready_notifications << true } }

  before do
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:on).with(:message) { |&callback| @receive = callback }
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    client.ready = ready
  end

  after { client.shutdown }

  def receive_frame(data)
    @receive.call(double('frame', data: data))
  end

  it 'delivers public events without credentials while suppressing acknowledged private events' do
    events = Queue.new
    client.subscribe(channel_name: :parent_order_events) { |message| events << message }
    client.subscribe(channel_name: :lightning_ticker_BTC_JPY) { |message| events << message }
    receive_frame('0{}')
    receive_frame('431[null]')
    receive_frame('432[null]')
    receive_frame('42["parent_order_events","private"]')
    receive_frame('42["lightning_ticker_BTC_JPY","public"]')

    expect(events.pop(timeout: 5)).to eq('public')
  end

  it 'sets heartbeat intervals and signals readiness on handshake' do
    receive_frame('0{"pingInterval":10000,"pingTimeout":5000}')

    expect(client.ping_interval).to eq(10_000)
    expect(client.ping_timeout).to eq(5_000)
    expect(ready_notifications.pop(timeout: 5)).to be(true)
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

  it 'caps pending payload bytes and frees them on dequeue, unsubscribe, and shutdown' do
    stub_const("#{described_class}::CALLBACK_PAYLOAD_LIMIT", 8)
    started = Queue.new
    resume = Queue.new
    failures = Queue.new
    client.subscription_failed = ->(channel, error) { failures << [channel, error] }
    receive_frame('0{}')
    client.subscribe(channel_name: :lightning_ticker_BTC_JPY) do |message|
      started << message
      resume.pop
    end
    client.subscribe(channel_name: :lightning_ticker_ETH_JPY) { |message| started << message }
    client.subscribe(channel_name: :lightning_executions_BTC_JPY) { |_message| }
    receive_frame('42["lightning_ticker_BTC_JPY","first"]')
    expect(started.pop(timeout: 5)).to eq('first')

    # Three multibyte characters and their JSON quotes fill the budget.
    receive_frame('42["lightning_ticker_BTC_JPY","ééé","x"]')
    receive_frame('433["rejected"]')
    allow(Time).to receive(:now).and_return(Time.at(123))
    receive_frame('3')
    expect(client.last_pong_at).to eq(123)
    resume << true
    expect(started.pop(timeout: 5)).to eq('ééé')

    receive_frame('42["lightning_ticker_ETH_JPY","stale!"]')
    expect(client.instance_variable_get(:@pending_callback_bytes)).to eq(8)
    client.unsubscribe(channel_name: :lightning_ticker_ETH_JPY)
    receive_frame('42["lightning_ticker_BTC_JPY","oversize","third"]')
    resume << true
    expect(started.pop(timeout: 5)).to eq('third')
    expect(failures.pop(timeout: 5)).to eq([:lightning_executions_BTC_JPY, 'rejected'])

    receive_frame('42["lightning_ticker_BTC_JPY","stale"]')
    client.shutdown
    expect(client.instance_variable_get(:@pending_callback_bytes)).to eq(0)
    expect(client.instance_variable_get(:@callback_queue)).to be_empty
  ensure
    resume&.close
  end

  it 'caps pending subscription failure payload bytes and frees them on dequeue and shutdown' do
    stub_const("#{described_class}::FAILURE_NOTIFICATION_PAYLOAD_LIMIT", 8)
    started = Queue.new
    resume = Queue.new
    failures = Queue.new
    client.subscription_failed = lambda do |channel, error|
      started << true
      resume.pop
      failures << [channel, error]
    end
    receive_frame('0{}')
    client.subscribe(channel_name: :lightning_ticker_BTC_JPY) { |_message| }
    client.subscribe(channel_name: :lightning_ticker_ETH_JPY) { |_message| }
    client.subscribe(channel_name: :lightning_executions_BTC_JPY) { |_message| }

    receive_frame('431["x"]')
    expect(started.pop(timeout: 5)).to be(true)

    # "oversize" exceeds the stubbed 8-byte budget while the callback worker is blocked, so it is dropped.
    receive_frame('432["oversize"]')
    expect(client.instance_variable_get(:@pending_failure_bytes)).to eq(0)

    # An ordinary small failure still fits the budget and reaches the callback.
    receive_frame('433["y"]')
    expect(client.instance_variable_get(:@pending_failure_bytes)).to eq(3)
    resume << true
    expect(failures.pop(timeout: 5)).to eq([:lightning_ticker_BTC_JPY, 'x'])
    expect(started.pop(timeout: 5)).to be(true)
    resume << true
    expect(failures.pop(timeout: 5)).to eq([:lightning_executions_BTC_JPY, 'y'])

    client.shutdown
    expect(client.instance_variable_get(:@pending_failure_bytes)).to eq(0)
    expect(client.instance_variable_get(:@callback_queue)).to be_empty
  ensure
    resume&.close
  end

  it 'frees callback capacity on unsubscribe and preserves the order of other queued events' do
    channel = :lightning_ticker_BTC_JPY
    started = Queue.new
    resume = Queue.new
    events = Queue.new
    callback = lambda do |message|
      if message == 'running'
        started << true
        resume.pop
      end
      events << message
    end
    receive_frame('0{}')
    client.subscribe(channel_name: channel, &callback)
    client.subscribe(channel_name: :lightning_ticker_ETH_JPY) { |message| events << message }
    receive_frame('42["lightning_ticker_BTC_JPY","running"]')
    expect(started.pop(timeout: 5)).to be(true)

    receive_frame('42["lightning_ticker_ETH_JPY","first"]')
    receive_frame("42#{JSON.generate([channel, *Array.new(1_022, 'stale')])}")
    receive_frame('42["lightning_ticker_ETH_JPY","second"]')
    receive_frame('42["lightning_ticker_ETH_JPY","overflow"]')
    client.unsubscribe(channel_name: channel)
    receive_frame('42["lightning_ticker_ETH_JPY","third"]')
    client.subscribe(channel_name: channel, &callback)
    receive_frame('42["lightning_ticker_BTC_JPY","fresh"]')
    resume << true

    expect(Array.new(5) { events.pop(timeout: 5) }).to eq(%w[running first second third fresh])
  ensure
    resume.close
  end

  it 'delivers the complete decoded large board event to its callback' do
    events = Queue.new
    channel = :lightning_board_BTC_JPY
    board = {
      'mid_price' => 5_000_000,
      'bids' => Array.new(3_000) { |index| { 'price' => 5_000_000 - index, 'size' => 0.125 } },
      'asks' => [{ 'price' => 5_000_001, 'size' => 0.25 }]
    }
    client.subscribe(channel_name: channel) { |message| events << message }

    receive_frame("42#{JSON.pretty_generate([channel, board])}")

    expect(events.pop(timeout: 5)).to eq(board)
  end

  context 'with API credentials' do
    let(:key) { 'key' }
    let(:secret) { 'secret' }

    it 'suppresses private events around authentication rejection' do
      events = Queue.new
      client.subscribe(channel_name: :parent_order_events) { |message| events << message }
      client.subscribe(channel_name: :lightning_ticker_BTC_JPY) { |message| events << message }
      receive_frame('0{}')
      receive_frame('42["parent_order_events","before rejection"]')
      receive_frame('42["lightning_ticker_BTC_JPY","public"]')
      expect(events.pop(timeout: 5)).to eq('public')

      receive_frame('430[{"message":"Invalid API key"}]')
      receive_frame('430[null]')
      receive_frame('431[null]')
      receive_frame('42["parent_order_events","after rejection"]')

      expect(socket).to have_received(:close).once
      expect(events).to be_empty
    end

    it 'logs a fixed diagnostic for a malformed private event and delivers the next event' do
      events = Queue.new
      client.subscribe(channel_name: :child_order_events) { |message| events << message }
      receive_frame('0{}')
      receive_frame('430[null]')
      receive_frame('431[null]')

      expect do
        receive_frame('42["child_order_events",{"order_id":INVALID"demo-private-order"}]')
      end.to output("Invalid JSON in realtime frame\n").to_stdout
      receive_frame('42["child_order_events",{"order_id":"valid-order"}]')
      expect(events.pop(timeout: 5)).to eq({ 'order_id' => 'valid-order' })
    end

    it 'requests authentication on handshake and signals readiness on acknowledgement' do
      receive_frame('0{}')

      expect(socket).to have_received(:send).with(start_with('420["auth",')).once
      expect(ready_notifications).to be_empty

      receive_frame('430[null]')

      expect(ready_notifications.pop(timeout: 5)).to be(true)
    end
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'debug logging' do
  subject(:client) { described_class.new(host: 'wss://example.test', key: 'key', secret: 'secret', debug: true) }

  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, on: nil, connect: nil, send: nil, closed?: false, close_for_shutdown: nil)
  end

  before do
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
  end

  after { client.shutdown }

  %w[child_order_events parent_order_events].each do |channel_name|
    it "logs only packet metadata and delivers the original #{channel_name} event" do
      event = [{ "#{channel_name.delete_suffix('_events')}_id" => 'dummy-private-order', 'size' => 0.1 }]
      payload = double('frame', data: "42#{[channel_name, event].to_json}")
      received = Queue.new
      expected_log = [
        'Received packet 42',
        "Received event on #{channel_name}"
      ].map(&:inspect).join("\n") + "\n"

      expect do
        client.subscribe(channel_name: channel_name.to_sym) { |message| received << message }
        %w[0{} 430[null] 431[null]].each { |data| client.handle_message(payload: double(data: data)) }
      end.to output(/Authenticated/).to_stdout
      expect { client.handle_message(payload: payload) }.to output(expected_log).to_stdout
      expect(received.pop(timeout: 5)).to eq(event)
    end
  end
end
