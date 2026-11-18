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
      double('websocket transport', open?: true, closed?: false, connect: nil, on: nil, close: nil, close_on_eof: nil)
    end

    before do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    end

    after { @client&.shutdown }

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
                           close_on_eof: nil)
      reconnected = Queue.new
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket, replacement)
      allow(replacement).to receive(:on).with(:close) { reconnected << true }
      @client = Bitflyer.realtime_client
      allow(socket).to receive(:open?).and_return(false)
      allow(socket).to receive(:closed?).and_return(true)

      Timeout.timeout(3) { reconnected.pop }
      @client.shutdown
      expect(replacement).to have_received(:close).once
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
  end
end
