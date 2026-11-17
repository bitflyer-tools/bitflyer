# frozen_string_literal: true

require 'spec_helper'
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
    let(:socket) { double('websocket transport', open?: true, on: nil, close: nil) }

    before do
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
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
      expect(WebSocket::Client::Simple).to have_received(:connect).once
    end

    it 'automatically reconnects after the transport closes while active' do
      replacement = double('replacement transport', open?: true, on: nil, close: nil)
      reconnected = Queue.new
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket, replacement)
      allow(replacement).to receive(:on).with(:close) { reconnected << true }
      @client = Bitflyer.realtime_client
      allow(socket).to receive(:open?).and_return(false)

      Timeout.timeout(3) { reconnected.pop }
      @client.shutdown
      expect(replacement).to have_received(:close).once
    end
  end
end
