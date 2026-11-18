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
  end

  describe '.realtime_client' do
    let(:socket) do
      double('websocket transport', open?: true, closed?: false, connect: nil, on: nil, close: nil,
             close_on_eof: nil, reset_error: nil)
    end

    before do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    end

    after { @client&.shutdown }

    let(:client) { @client = Bitflyer.realtime_client }
    let(:session) { client.websocket_client }
    let(:connected_at) { Time.at(1_000) }


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

    it 'automatically reconnects after the transport closes while active' do
      replacement = double('replacement transport', open?: true, closed?: false, connect: nil, on: nil, close: nil,
                           close_on_eof: nil, reset_error: nil)
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
      end

      @client = Bitflyer.realtime_client('key', 'secret')
      @client.ready = -> { ready << true }
      @client.ticker_btc_jpy = ->(_message) {}
      allow(socket).to receive(:closed?).and_return(true)
      @client.websocket_client.reconnect

      expect(replacement).to have_received(:send).with(start_with('420["auth",')).ordered
      expect(replacement).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').ordered
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

    it 'exposes heartbeat state initialized and updated by the WebSocket session' do
      allow(Time).to receive(:now).and_return(connected_at)
      session.setup_by_response(json: '{"pingInterval":5000,"pingTimeout":6000}')

      expect(client).to have_attributes(ping_interval: 5_000, ping_timeout: 6_000,
                                        last_ping_at: connected_at.to_i, last_pong_at: connected_at.to_i)

      allow(Time).to receive(:now).and_return(connected_at + 6)
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
  end
end
