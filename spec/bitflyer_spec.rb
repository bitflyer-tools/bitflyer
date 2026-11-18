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
      double('websocket transport', open?: true, closed?: false, connect: nil, on: nil, close: nil,
             close_on_eof: nil, read_error: nil, send: nil)
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

    it 'returns a Realtime::Client instance' do
      @client = Bitflyer.realtime_client
      expect(@client).to be_a(Bitflyer::Realtime::Client)
    end

    it 'closes the transport once, stops its monitor, and ignores later recovery requests' do
      error_callback = nil
      allow(socket).to receive(:on).with(:error) { |&callback| error_callback = callback }
      allow(socket).to receive(:close) { allow(socket).to receive(:open?).and_return(false) }
      @client = Bitflyer.realtime_client
      monitor = @client.websocket_client.instance_variable_get(:@monitor)
      expect(monitor).to be_alive

      @client.shutdown
      @client.shutdown
      error_callback.call(Errno::ECONNRESET.new)
      @client.websocket_client.reconnect

      expect(monitor).not_to be_alive
      expect(socket).to have_received(:close).once
      expect(Bitflyer::Realtime::Transport).to have_received(:new).once
    end

    it 'waits for the connection to close in concurrent shutdown calls' do
      close_started = Queue.new
      release_close = Queue.new
      monitor = session.instance_variable_get(:@monitor)
      allow(socket).to receive(:close) do
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
      expect(socket).to have_received(:close).once
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
          stub_const('Bitflyer::Realtime::SOCKET_HOST', "http://127.0.0.1:#{server.addr[1]}")
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
            handshake = WebSocket::Handshake::Server.new
            handshake << peer.gets("\r\n\r\n")
            peer.write(handshake.to_s)
            peer.write(WebSocket::Frame::Outgoing::Server.new(version: handshake.version, type: :text,
                                                               data: payload).to_s)

            expect(completed.pop).to equal(transport.thread)
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
      replacement = double('replacement transport', open?: true, closed?: false, connect: nil, on: nil, close: nil,
                           close_on_eof: nil, read_error: nil)
      reconnected = Queue.new
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)
      allow(replacement).to receive(:close_on_eof) { reconnected << true }
      @client = Bitflyer.realtime_client
      allow(socket).to receive(:open?).and_return(false)
      allow(socket).to receive(:closed?).and_return(true)

      Timeout.timeout(3) { reconnected.pop }
      @client.shutdown
      expect(replacement).to have_received(:close).once
    end

    it 'closes the socket to interrupt a blocked ping before joining the monitor' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      transport = Bitflyer::Realtime::Transport.new
      ping_started = Queue.new
      write_released = Queue.new
      raw_socket = double('socket', getc: nil)
      handshake = double('handshake', finished?: true, version: 13)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@handshake, handshake)
        transport.instance_variable_set(:@handshaked, true)
      end
      allow(raw_socket).to receive(:write) do |frame|
        next if frame.getbyte(0) == 0x88

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
      raw_socket = double('socket', getc: nil, close: nil)
      handshake = double('handshake', finished?: true)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@handshake, handshake)
        transport.instance_variable_set(:@handshaked, true)
      end
      allow(handshake).to receive(:version) do
        ping_started << true
        write_released.pop
        13
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
      raw_socket = double('socket', getc: nil)
      handshake = double('handshake', finished?: true, version: 13)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:connect) do
        transport.instance_variable_set(:@socket, raw_socket)
        transport.instance_variable_set(:@handshake, handshake)
        transport.instance_variable_set(:@handshaked, true)
      end
      allow(raw_socket).to receive(:write) do |frame|
        close_started << frame.getbyte(0)
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
        expect(close_started.pop).to eq(0x88)
        client.shutdown
      end

      expect(raw_socket).to have_received(:close).once
      expect(monitor).not_to be_alive
    ensure
      write_released << true
    end

    it 'authenticates, resubscribes, and signals readiness when the greeting arrives during connect' do
      replacement = double('replacement transport', close_on_eof: nil, close: nil)
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
      allow(socket).to receive(:closed?).and_return(true)
      @client.websocket_client.reconnect

      expect(replacement).to have_received(:send).with(start_with('420["auth",')).ordered
      expect(replacement).to have_received(:send).with('421["subscribe","lightning_ticker_BTC_JPY"]').ordered
      expect(ready.size).to eq(1)
    end

    it 'keeps the pending handshake through a monitor tick and releases the transport on shutdown' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        stub_const('Bitflyer::Realtime::SOCKET_HOST', "http://127.0.0.1:#{server.addr[1]}")
        @client = Bitflyer.realtime_client
        websocket = @client.websocket_client
        transport = websocket.websocket_client
        receiver = transport.thread
        tick = Queue.new
        allow(websocket).to receive(:reconnect).and_wrap_original do |reconnect|
          reconnect.call
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
        allow(socket).to receive(:closed?).and_return(true)

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

    it 'reconnects after the peer closes during the WebSocket handshake' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        stub_const('Bitflyer::Realtime::SOCKET_HOST', "http://127.0.0.1:#{server.addr[1]}")
        @client = Bitflyer.realtime_client
        transport = @client.websocket_client.websocket_client
        disconnected = Queue.new
        @client.disconnected = ->(error) { disconnected << error }

        peer = replacement_peer = nil
        Timeout.timeout(5) do
          peer = server.accept
          peer.each_line { |line| break if line == "\r\n" }
          peer.close
          disconnected.pop
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

    it 'reconnects after the peer resets the connection during the WebSocket handshake' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        stub_const('Bitflyer::Realtime::SOCKET_HOST', "http://127.0.0.1:#{server.addr[1]}")
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

    it 'reconnects when the ping write detects a reset before the reader' do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
      TCPServer.open('127.0.0.1', 0) do |server|
        stub_const('Bitflyer::Realtime::SOCKET_HOST', "http://127.0.0.1:#{server.addr[1]}")
        transport = session.websocket_client
        ready = Queue.new
        disconnected = Queue.new
        client.ready = -> { ready << true }
        client.disconnected = ->(error) { disconnected << error }
        reset = Errno::ECONNRESET.new

        peer = replacement_peer = nil
        Timeout.timeout(5) do
          peer = server.accept
          handshake = WebSocket::Handshake::Server.new
          handshake << peer.gets("\r\n\r\n")
          peer.write(handshake.to_s)
          peer.write(WebSocket::Frame::Outgoing::Server.new(version: handshake.version, type: :text,
                                                             data: '0{}').to_s)
          ready.pop

          raw_socket = transport.instance_variable_get(:@socket)
          allow(raw_socket).to receive(:write).and_raise(reset)
          client.ping_interval = 0

          expect(disconnected.pop).to equal(reset)
          replacement_peer = server.accept
          expect(replacement_peer.gets("\r\n\r\n")).to start_with('GET /socket.io/')
          expect(transport).to be_closed
          expect(transport.thread.join(1)).to eq(transport.thread)
          expect(disconnected).to be_empty
        end
      ensure
        @client&.shutdown
        peer&.close
        replacement_peer&.close
      end
    end

    %i[reset eof].product([nil, IOError.new('stream closed in another thread')]).each do |disconnect, write_error|
      it "reconnects after #{disconnect} interrupts ping with #{write_error&.class || NoMethodError}" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        transport = Bitflyer::Realtime::Transport.new
        replacement = double('replacement transport', open?: true, connect: nil, on: nil, close: nil)
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport, replacement)

        ping_started = Queue.new
        write_released = Queue.new
        reconnected = Queue.new
        raw_socket = double('socket', getc: nil, close: nil)
        handshake = double('handshake', finished?: true, version: 13)
        if write_error
          allow(raw_socket).to receive(:write) do
            next if Thread.current == transport.thread

            ping_started << true
            write_released.pop
            raise write_error
          end
        else
          allow(raw_socket).to receive(:write)
          allow(handshake).to receive(:version) do
            next 13 if Thread.current == transport.thread

            ping_started << true
            write_released.pop
            13
          end
        end
        allow(transport).to receive(:connect) do
          transport.instance_variable_set(:@socket, raw_socket)
          transport.instance_variable_set(:@handshake, handshake)
          transport.instance_variable_set(:@handshaked, true)
          transport.once(:__close) { |error| transport.emit(:close, error) }
        end
        allow(replacement).to receive(:close_on_eof) { reconnected << true }
        read_error = Errno::ECONNRESET.new if disconnect == :reset
        disconnected = Queue.new
        client.disconnected = ->(error) { disconnected << error }
        client.ping_interval = 0
        client.last_ping_at = Time.now.to_i - 1

        Timeout.timeout(5) do
          ping_started.pop
          reader = Thread.new do
            transport.instance_variable_set(:@thread, Thread.current)
            read_error ? transport.emit(:error, read_error) : raw_socket.getc
          end
          reader.join
          write_released << true
          reconnected.pop
        end

        expect(disconnected.pop(true)).to eq(read_error)
        expect(raw_socket).to have_received(:close).once
        expect(session.websocket_client).to equal(replacement)
      ensure
        write_released << true
      end
    end

    [Errno::ECONNRESET, OpenSSL::SSL::SSLError].each do |read_error|
      it "retries when #{read_error} clears the socket before the handshake write" do
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_call_original
        interrupted_transport = Bitflyer::Realtime::Transport.new
        replacement = double('replacement transport', open?: true, connect: nil, on: nil, close: nil)
        raw_socket = double('socket', close: nil)
        peer = raw_socket
        url = 'ws://example.test'
        if read_error == OpenSSL::SSL::SSLError
          peer = instance_double(OpenSSL::SSL::SSLSocket, connect: nil, close: nil, 'sync_close=': nil, 'hostname=': nil)
          allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(peer)
          url = 'wss://example.test'
        end
        allow(peer).to receive(:getc).and_raise(read_error)
        allow(TCPSocket).to receive(:new).and_return(raw_socket)
        allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, interrupted_transport, replacement)

        connector = nil
        allow(interrupted_transport).to receive(:connect).and_wrap_original do |connect, url|
          connector = Thread.current
          connect.call(url)
        end
        allow(Thread).to receive(:new).and_wrap_original do |start, &block|
          thread = start.call(&block)
          thread.join(1) if Thread.current == connector
          thread
        end

        reconnected = Queue.new
        allow(replacement).to receive(:close_on_eof) { reconnected << true }
        allow($stdout).to receive(:puts)
        stub_const('Bitflyer::Realtime::SOCKET_HOST', url)
        disconnected = Queue.new
        client.disconnected = ->(error) { disconnected << error }
        allow(socket).to receive_messages(open?: false, closed?: true)

        Timeout.timeout(5) { reconnected.pop }
        expect(disconnected.pop(true)).to be_a(read_error)
        expect(peer).to have_received(:close).once
        expect(session.websocket_client).to equal(replacement)
      ensure
        interrupted_transport&.close_for_shutdown
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
      disconnected = spy('disconnected callback')
      client.ready = ready
      client.disconnected = disconnected

      allow(socket).to receive(:close) do
        allow(socket).to receive(:closed?).and_return(true)
        handlers.fetch(:close).call(nil)
      end
      receive_frame('0{}')
      client.websocket_client.last_pong_at = 0
      receive_frame('430[{"message":"Invalid API key"}]')
      receive_frame('3')
      receive_frame('430[null]')
      client.websocket_client.reconnect

      expect(socket).to have_received(:close).once
      expect(disconnected).to have_received(:call)
        .with(an_object_having_attributes(message: 'Authentication failed: [{"message":"Invalid API key"}]')).once
      expect(ready).not_to have_received(:call)
      expect(client.websocket_client.last_pong_at).to eq(0)
      expect(socket).to have_received(:connect).once
    end

    it 'signals readiness after authentication succeeds' do
      client = @client = Bitflyer.realtime_client('key', 'secret')
      ready = spy('ready callback')
      client.ready = ready

      receive_frame('0{}')
      expect(ready).not_to have_received(:call)
      receive_frame('430[null]')

      expect(ready).to have_received(:call).once
      expect(socket).not_to have_received(:close)
    end

    it 'reports authentication rejection once when closing the socket fails' do
      client = @client = Bitflyer.realtime_client('key', 'secret')
      disconnected = spy('disconnected callback')
      client.disconnected = disconnected
      reset = Errno::ECONNRESET.new
      allow(socket).to receive(:close).and_raise(reset)

      receive_frame('0{}')
      receive_frame('430[{"message":"Invalid API key"}]')
      message = 'Authentication failed: [{"message":"Invalid API key"}]'
      expect(disconnected).to have_received(:call).once.with(
        be_an_instance_of(RuntimeError).and(have_attributes(message: message))
      )

      allow(socket).to receive(:close)
      handlers.fetch(:error).call(reset)
      handlers.fetch(:close).call(reset)
      expect(disconnected).to have_received(:call).once
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
