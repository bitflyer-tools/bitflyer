# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'

describe Bitflyer do
  it 'has a version number' do
    expect(Bitflyer::VERSION).not_to be_nil
  end

  describe '.http_public_client' do
    it 'returns a Public::Client instance' do
      expect(Bitflyer.http_public_client).to be_a(Bitflyer::HTTP::Public::Client)
    end
  end

  describe '.http_private_client' do
    it 'returns a Private::Client instance' do
      client = Bitflyer.http_private_client('key', 'secret')
      expect(client).to be_a(Bitflyer::HTTP::Private::Client)
    end

    it 'omits credentials from client and connection inspection' do
      client = Bitflyer.http_private_client('test_api_key', 'test_api_secret')
      connection = client.instance_variable_get(:@connection)

      [client, connection].each do |object|
        expect(object.inspect).not_to include('test_api_key')
        expect(object.inspect).not_to include('test_api_secret')
      end
    end
  end

  describe '.realtime_client' do
    let(:socket) do
      double('websocket transport', open?: true, closed?: false, reconnectable?: false, connect: nil, on: nil, close: nil,
             close_for_shutdown: nil, send: nil)
    end

    before do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    end

    after { @client&.shutdown }

    let(:client) { @client = Bitflyer.realtime_client }
    let(:session) { client.websocket_client }
    let(:handlers) { {} }
    let(:connected_at) { Time.at(1_000) }

    before do
      allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
      allow(Time).to receive(:now).and_return(connected_at)
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond).and_return(10_000)
    end

    def use_tcp_peer(server)
      stub_const('Bitflyer::Realtime::SOCKET_HOST', "https://127.0.0.1:#{server.addr[1]}")
      allow_any_instance_of(Bitflyer::Realtime::Transport).to receive(:connect_tls) do |_, uri|
        TCPSocket.new(uri.hostname, uri.port)
      end
    end

    def send_greeting(peer, payload = nil)
      driver = WebSocket::Driver.server(peer)
      driver.on(:connect) do
        driver.start
        driver.text(payload) if payload
      end
      driver.parse(peer.gets("\r\n\r\n"))
      driver
    end

    def read_realtime_frame(peer, driver)
      frame = nil
      driver.on(:message) { |event| frame ||= event.data }
      driver.parse(peer.readpartial(4096)) until frame
      frame
    end

    it 'returns a Realtime::Client instance' do
      @client = Bitflyer.realtime_client
      expect(@client).to be_a(Bitflyer::Realtime::Client)
    end

    it 'closes the transport once, stops its monitor, and ignores later recovery requests' do
      allow(socket).to receive(:close_for_shutdown) { allow(socket).to receive(:open?).and_return(false) }
      @client = Bitflyer.realtime_client
      monitor = @client.websocket_client.instance_variable_get(:@monitor)
      expect(monitor).to be_alive

      @client.shutdown
      @client.shutdown
      handlers.fetch(:close).call(Errno::ECONNRESET.new)
      @client.websocket_client.reconnect

      expect(monitor).not_to be_alive
      expect(socket).to have_received(:close_for_shutdown).once
      expect(Bitflyer::Realtime::Transport).to have_received(:new).once
    end

    it 'waits for the connection to close in concurrent shutdown calls' do
      close_started = Queue.new
      release_close = Queue.new
      monitor = session.instance_variable_get(:@monitor)
      allow(socket).to receive(:close_for_shutdown) do
        close_started << true
        release_close.pop
      end

      first_shutdown = Thread.new { client.shutdown }
      Timeout.timeout(5) { close_started.pop }
      expect(monitor.join(5)).to eq(monitor)

      second_shutdown = Thread.new { client.shutdown }
      Timeout.timeout(5) { Thread.pass while second_shutdown.status == 'run' }
      expect(second_shutdown.status).to eq('sleep')

      release_close << true
      expect(first_shutdown.join(5)).to eq(first_shutdown)
      expect(second_shutdown.join(5)).to eq(second_shutdown)
      expect(socket).to have_received(:close_for_shutdown).once
    ensure
      release_close << true
      first_shutdown&.join(5)
      second_shutdown&.join(5)
    end

    {
      ready: '0{}',
      ticker_btc_jpy: '42["lightning_ticker_BTC_JPY",{}]'
    }.each do |callback, payload|
      it "returns from shutdown inside the #{callback} callback" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        TCPServer.open('127.0.0.1', 0) do |server|
          use_tcp_peer(server)
          transport = session.websocket_client
          monitor = session.instance_variable_get(:@monitor)
          completed = Queue.new
          stop_client = lambda do |*|
            client.shutdown
            completed << Thread.current
          end
          client.public_send(:"#{callback}=", stop_client)

          peer = nil
          Timeout.timeout(5) do
            peer = server.accept
            send_greeting(peer, payload)

            callback_thread = completed.pop
            expect(callback_thread).not_to equal(transport.thread)
            expect(callback_thread.join(1)).to equal(callback_thread)
            expect(transport.thread.join(1)).to equal(transport.thread)
            expect(transport).to be_closed
            expect(monitor).not_to be_alive
            expect(peer).to be_eof
          end
        ensure
          peer&.close
        end
      end
    end

    it 'automatically reconnects after the transport closes while active' do
      replacement = double('replacement transport', open?: true, closed?: false, reconnectable?: false, connect: nil, on: nil, close: nil,
                           close_for_shutdown: nil)
      reconnected = Queue.new
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)
      allow(replacement).to receive(:connect) { reconnected << true }
      @client = Bitflyer.realtime_client
      allow(socket).to receive(:open?).and_return(false)
      allow(socket).to receive(:reconnectable?).and_return(true)

      Timeout.timeout(3) { reconnected.pop }
      @client.shutdown
      expect(replacement).to have_received(:close_for_shutdown).once
    end

    it 'closes the socket to interrupt a blocked ping before joining the monitor' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      transport = Bitflyer::Realtime::Transport.new
      ping_started = Queue.new
      write_released = Queue.new
      raw_socket = double('socket')
      driver = instance_double(WebSocket::Driver, state: :open)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@driver, driver)
      end
      allow(driver).to receive(:text) { transport.write('ping') }
      allow(raw_socket).to receive(:write) do

        ping_started << true
        write_released.pop
        raise IOError, 'stream closed in another thread'
      end
      allow(raw_socket).to receive(:close) { write_released << true }

      client.ping_interval = 0
      client.last_ping_at = Time.now.to_i - 1
      monitor = session.instance_variable_get(:@monitor)

      Timeout.timeout(5) do
        ping_started.pop
        client.shutdown
      end

      expect(raw_socket).to have_received(:write).once
      expect(raw_socket).to have_received(:close).once
      expect(monitor).not_to be_alive
    ensure
      write_released << true
    end

    it 'stops the monitor when shutdown clears the socket before the ping writes' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      transport = Bitflyer::Realtime::Transport.new
      ping_started = Queue.new
      write_released = Queue.new
      raw_socket = double('socket', close: nil)
      driver = instance_double(WebSocket::Driver, state: :open)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@driver, driver)
      end
      allow(driver).to receive(:text) do
        ping_started << true
        write_released.pop
        transport.write('ping')
      end
      allow(transport).to receive(:close_for_shutdown).and_wrap_original do |close|
        close.call
        write_released << true
      end

      client.ping_interval = 0
      client.last_ping_at = connected_at.to_i
      monitor = session.instance_variable_get(:@monitor)

      Timeout.timeout(5) do
        ping_started.pop
        client.shutdown
      end

      expect(raw_socket).to have_received(:close).once
      expect(monitor).not_to be_alive
    ensure
      write_released << true
    end

    it 'stops the monitor when shutdown interrupts the pong timeout close frame' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      transport = Bitflyer::Realtime::Transport.new
      close_started = Queue.new
      write_released = Queue.new
      raw_socket = double('socket')
      driver = instance_double(WebSocket::Driver, state: :open)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@driver, driver)
      end
      allow(driver).to receive(:close) { transport.write('close') }
      allow(raw_socket).to receive(:write) do |frame|
        close_started << frame
        write_released.pop
        raise IOError, 'stream closed in another thread'
      end
      allow(raw_socket).to receive(:close) { write_released << true }

      session.ping_interval = 1_000
      session.ping_timeout = 1_000
      session.last_pong_at = connected_at.to_i - 2
      monitor = session.instance_variable_get(:@monitor)
      monitor.report_on_exception = false

      Timeout.timeout(5) do
        expect(close_started.pop).to eq('close')
        client.shutdown
      end

      expect(raw_socket).to have_received(:close).once
      expect(monitor).not_to be_alive
    ensure
      write_released << true
    end

    it 'authenticates, resubscribes, and signals readiness when the greeting arrives during connect' do
      replacement = double('replacement transport', closed?: false, reconnectable?: false, close_for_shutdown: nil, close: nil)
      callbacks = {}
      ready = Queue.new
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)
      allow(socket).to receive(:send)
      allow(replacement).to receive(:on) { |event, &callback| callbacks[event] = callback }
      allow(replacement).to receive(:send)
      allow(replacement).to receive(:connect) do
        callbacks[:open]&.call
        callbacks[:message]&.call(double(data: '0{"pingInterval":25000}'))
        callbacks[:message]&.call(double(data: '430[null]'))
        callbacks[:message]&.call(double(data: '431[null]'))
      end

      @client = Bitflyer.realtime_client('key', 'secret')
      @client.ready = -> { ready << true }
      @client.ticker_btc_jpy = ->(_message) {}
      allow(socket).to receive(:reconnectable?).and_return(true)
      @client.websocket_client.reconnect

      expect(replacement).to have_received(:send).with(start_with('420["auth",')).ordered
      expect(replacement).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').ordered
      expect(ready.pop(timeout: 5)).to be(true)
    end

    it 'keeps the pending handshake through a monitor tick and releases the transport on shutdown' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        use_tcp_peer(server)
        @client = Bitflyer.realtime_client
        websocket = @client.websocket_client
        transport = websocket.websocket_client
        receiver = transport.thread
        tick = Queue.new
        allow(websocket).to receive(:poll_transport).and_wrap_original do |poll|
          poll.call
          tick << true
        end

        peer = Timeout.timeout(5) { server.accept }
        Timeout.timeout(5) do
          peer.each_line { |line| break if line == "\r\n" }
          tick.pop
          expect(transport).not_to be_open
          expect(Bitflyer::Realtime::Transport).to have_received(:new).once

          @client.shutdown
          expect(peer.eof?).to be(true)
          expect(receiver.join(1)).to eq(receiver)
        end
      ensure
        transport&.close
        peer&.close
      end
    end

    it 'stops the monitor and closes the socket during a stalled TLS reconnect' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      replacement = Bitflyer::Realtime::Transport.new
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)

      TCPServer.open('127.0.0.1', 0) do |server|
        stub_const('Bitflyer::Realtime::SOCKET_HOST', "https://127.0.0.1:#{server.addr[1]}")
        @client = Bitflyer.realtime_client
        monitor = @client.websocket_client.instance_variable_get(:@monitor)
        allow(socket).to receive(:open?).and_return(false)
        allow(socket).to receive(:reconnectable?).and_return(true)

        peer = nil
        Timeout.timeout(5) do
          peer = server.accept
          expect(peer.readpartial(1)).to eq("\x16")
          @client.shutdown
          peer.read
          expect(peer).to be_eof
        end

        expect(monitor).not_to be_alive
        expect(replacement).to be_closed
        expect(@client.websocket_client.websocket_client).to equal(socket)
      ensure
        peer&.close
      end
    end

    [false, true].each do |upgraded|
      it "reconnects after EOF #{upgraded ? 'after' : 'during'} the WebSocket handshake" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        TCPServer.open('127.0.0.1', 0) do |server|
          use_tcp_peer(server)
          @client = Bitflyer.realtime_client
          transport = @client.websocket_client.websocket_client
          disconnected = Queue.new
          @client.disconnected = ->(error) { disconnected << error }

          ready = Queue.new
          @client.ready = -> { ready << true }
          peer = replacement_peer = nil
          Timeout.timeout(5) do
            peer = server.accept
            if upgraded
              send_greeting(peer, '0{}')
              ready.pop
            else
              peer.gets("\r\n\r\n")
            end
            peer.close
            expect(disconnected.pop).to be_nil
            replacement_peer = server.accept
            replacement_peer.each_line { |line| break if line == "\r\n" }
            expect(transport).to be_closed
            expect(transport.thread.join(1)).to eq(transport.thread)
            expect(Bitflyer::Realtime::Transport).to have_received(:new).twice
          end
        ensure
          @client&.shutdown
          peer&.close
          replacement_peer&.close
        end
      end
    end

    it 'reconnects after the peer resets the connection during the WebSocket handshake' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        use_tcp_peer(server)
        @client = Bitflyer.realtime_client
        transport = @client.websocket_client.websocket_client
        disconnected = Queue.new
        @client.disconnected = ->(error) { disconnected << [error, transport.closed?] }

        peer = replacement_peer = nil
        Timeout.timeout(5) do
          peer = server.accept
          peer.each_line { |line| break if line == "\r\n" }
          peer.setsockopt(Socket::Option.linger(true, 0))
          peer.close
          expect(disconnected.pop).to match([an_instance_of(Errno::ECONNRESET), true])
          replacement_peer = server.accept
          expect(transport).to be_closed
          expect(transport.thread.join(1)).to eq(transport.thread)
          expect(Bitflyer::Realtime::Transport).to have_received(:new).twice
          expect(disconnected).to be_empty
        end
      ensure
        @client&.shutdown
        peer&.close
        replacement_peer&.close
      end
    end

    %i[heartbeat authentication live_subscription subscription_replay].each do |write|
      it "reconnects when a #{write} write detects a reset before the reader" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        TCPServer.open('127.0.0.1', 0) do |server|
          use_tcp_peer(server)
          credentials = write == :authentication ? %w[key secret] : []
          @client = Bitflyer.realtime_client(*credentials)
          transport = @client.websocket_client.websocket_client
          ready = Queue.new
          disconnected = Queue.new
          messages = Queue.new
          callback = ->(message) { messages << message }
          @client.ready = -> { ready << true }
          @client.disconnected = ->(error) { disconnected << error }
          reset = Errno::ECONNRESET.new

          peer = replacement_peer = nil
          Timeout.timeout(5) do
            peer = server.accept
            driver = send_greeting(peer)
            if %i[heartbeat live_subscription].include?(write)
              driver.text('0{}')
              ready.pop
            end

            raw_socket = transport.instance_variable_get(:@socket)
            allow(raw_socket).to receive(:write).and_raise(reset)
            case write
            when :heartbeat
              @client.ping_interval = 0
            when :live_subscription
              @client.ticker_btc_jpy = callback
            else
              @client.ticker_btc_jpy = callback if write == :subscription_replay
              driver.text('0{}')
            end

            expect(disconnected.pop).to equal(reset)
            expect(ready).to be_empty
            expect(transport).to be_closed
            expect(transport.thread.join(1)).to eq(transport.thread)

            replacement_peer = server.accept
            driver = send_greeting(replacement_peer, '0{}')
            if write == :authentication
              expect(read_realtime_frame(replacement_peer, driver)).to start_with('420["auth",')
              driver.text('430[null]')
            end
            if %i[live_subscription subscription_replay].include?(write)
              expect(read_realtime_frame(replacement_peer, driver)).to eq('421["subscribe","lightning_ticker_BTC_JPY"]')
              expect(ready).to be_empty
              driver.text('431[null]')
            end
            ready.pop
            expect(disconnected).to be_empty
            if %i[live_subscription subscription_replay].include?(write)
              driver.text('42["lightning_ticker_BTC_JPY",{"price":1}]')
              expect(messages.pop).to eq('price' => 1)
            end
          end
        ensure
          @client&.shutdown
          peer&.close
          replacement_peer&.close
        end
      end
    end

    %i[reset eof].each do |disconnect|
      it "reconnects after #{disconnect} closes the socket during a ping write" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        transport = Bitflyer::Realtime::Transport.new
        replacement = double('replacement transport', open?: true, on: nil, close_for_shutdown: nil)
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport, replacement)
        ping_started = Queue.new
        write_released = Queue.new
        reconnected = Queue.new
        disconnected = Queue.new
        raw_socket = double('socket')
        driver = instance_double(WebSocket::Driver, state: :open)
        allow(transport).to receive(:connect) do
          transport.instance_variable_set(:@socket, raw_socket)
          transport.instance_variable_set(:@driver, driver)
        end
        allow(driver).to receive(:text) { transport.write('ping') }
        allow(raw_socket).to receive(:write) do
          ping_started << true
          write_released.pop
          raise IOError, 'stream closed in another thread'
        end
        allow(raw_socket).to receive(:close) { write_released << true }
        allow(replacement).to receive(:connect) { reconnected << true }
        read_error = Errno::ECONNRESET.new if disconnect == :reset
        allow(raw_socket).to receive(:readpartial).and_raise(read_error || EOFError)
        client.disconnected = ->(error) { disconnected << error }
        client.ping_interval = 0
        client.last_ping_at = Time.now.to_i - 1

        Timeout.timeout(5) do
          ping_started.pop
          transport.__send__(:read_messages)
          reconnected.pop
        end

        expect(disconnected.pop(true)).to eq(read_error)
        expect(raw_socket).to have_received(:close).once
      ensure
        write_released << true
      end
    end

    [Errno::ECONNRESET, OpenSSL::SSL::SSLError].each do |write_error|
      it "retries when #{write_error} interrupts the handshake request" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        interrupted_transport = Bitflyer::Realtime::Transport.new
        replacement = double('replacement transport', open?: true, on: nil, close_for_shutdown: nil)
        peer = double('socket', close: nil)
        allow(peer).to receive(:write).and_raise(write_error)
        allow(interrupted_transport).to receive(:connect_tls).and_return(peer)
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, interrupted_transport, replacement)

        reconnected = Queue.new
        allow(replacement).to receive(:connect) { reconnected << true }
        allow($stdout).to receive(:puts)
        client
        allow(socket).to receive_messages(open?: false, reconnectable?: true)

        Timeout.timeout(5) { reconnected.pop }
        expect(peer).to have_received(:close).once
      end
    end

    it 'exposes heartbeat state initialized and updated by the WebSocket session' do
      allow(Time).to receive(:now).and_return(connected_at)
      session.setup_by_response(json: '{"pingInterval":5000,"pingTimeout":6000}')

      expect(client).to have_attributes(ping_interval: 5_000, ping_timeout: 6_000,
                                        last_ping_at: connected_at.to_i, last_pong_at: connected_at.to_i)

      allow(Time).to receive(:now).and_return(connected_at + 6)
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond).and_return(16_000)
      expect(socket).to receive(:send).with('2')
      session.send_ping
      session.receive_pong

      expect(client).to have_attributes(last_ping_at: connected_at.to_i + 6, last_pong_at: connected_at.to_i + 6)
    end

    it 'uses heartbeat values written through the public client when monitoring' do
      allow(Time).to receive(:now).and_return(connected_at)
      session.setup_by_response(json: '{}')
      client.ping_interval = 2_000
      client.ping_timeout = 1_000
      client.last_ping_at = connected_at.to_i - 3
      client.last_pong_at = connected_at.to_i - 4

      expect(socket).to receive(:send).with('2')
      expect(socket).to receive(:close)
      session.send_ping
      session.wait_pong
    end

    it 'reports authentication rejection and closes the rejected session' do
      client = @client = Bitflyer.realtime_client('key', 'secret')
      ready = spy('ready callback')
      disconnected = Queue.new
      client.ready = ready
      client.disconnected = ->(error) { disconnected << error }

      allow(socket).to receive(:close) do
        allow(socket).to receive(:reconnectable?).and_return(true)
        handlers.fetch(:close).call(nil)
      end
      receive_frame('0{}')
      client.websocket_client.last_pong_at = 0
      receive_frame('430[{"message":"Invalid API key"}]')
      receive_frame('3')
      receive_frame('430[null]')
      client.websocket_client.reconnect

      expect(socket).to have_received(:close).once
      expect(disconnected.pop(timeout: 5)).to have_attributes(message: 'Authentication failed: [{"message":"Invalid API key"}]')
      expect(disconnected).to be_empty
      expect(ready).not_to have_received(:call)
      expect(client.websocket_client.last_pong_at).to eq(0)
      expect(socket).to have_received(:connect).once
    end

    it 'signals readiness after authentication succeeds' do
      client = @client = Bitflyer.realtime_client('key', 'secret')
      ready = Queue.new
      client.ready = -> { ready << true }

      receive_frame('0{}')
      expect(ready).to be_empty
      receive_frame('430[null]')

      expect(ready.pop(timeout: 5)).to be(true)
      expect(socket).not_to have_received(:close)
    end

    it 'reports authentication rejection once when closing the socket fails' do
      client = @client = Bitflyer.realtime_client('key', 'secret')
      disconnected = Queue.new
      client.disconnected = ->(error) { disconnected << error }
      reset = Errno::ECONNRESET.new
      allow(socket).to receive(:close).and_raise(reset)

      receive_frame('0{}')
      receive_frame('430[{"message":"Invalid API key"}]')
      message = 'Authentication failed: [{"message":"Invalid API key"}]'
      expect(disconnected.pop(timeout: 5)).to be_an_instance_of(RuntimeError).and(have_attributes(message: message))

      allow(socket).to receive(:close)
      handlers.fetch(:close).call(reset)
      expect(disconnected).to be_empty
      expect(socket).to have_received(:connect).once
    end

    def receive_frame(data)
      handlers.fetch(:message).call(double(data: data))
    end

    context 'with credentials' do
      let(:client) { @client = Bitflyer.realtime_client('test_api_key', 'test_api_secret') }

      it 'omits credentials from client and connection inspection' do
        [client, client.websocket_client].each do |object|
          expect(object.inspect).not_to include('test_api_key')
          expect(object.inspect).not_to include('test_api_secret')
        end
      end

      it 'authenticates with the original credentials' do
        allow(socket).to receive(:send) do |message|
          expect(message).to start_with('420')
          event, params = JSON.parse(message.delete_prefix('420'))
          expected_signature = OpenSSL::HMAC.hexdigest(
            'sha256', 'test_api_secret', "#{params.fetch('timestamp')}#{params.fetch('nonce')}"
          )
          expect(event).to eq('auth')
          expect(params).to include('api_key' => 'test_api_key', 'signature' => expected_signature)
        end

        client.websocket_client.setup_by_response(json: '{}')

        expect(socket).to have_received(:send).once
      end
    end
  end
end
