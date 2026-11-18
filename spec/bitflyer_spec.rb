# frozen_string_literal: true

require 'spec_helper'

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
    let(:socket) { instance_double(WebSocket::Client::Simple::Client, send: nil, open?: false) }
    let(:handlers) { {} }
    let(:client) { Bitflyer.realtime_client }
    let(:session) { client.websocket_client }
    let(:connected_at) { Time.at(1_000) }

    before do
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
      allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
      allow(socket).to receive(:close) { handlers.fetch(:close).call(nil) }
      allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
      allow(Time).to receive(:now).and_return(connected_at)
    end

    it 'returns a Realtime::Client instance' do
      expect(client).to be_a(Bitflyer::Realtime::Client)
    end

    it 'exposes heartbeat state initialized and updated by the WebSocket session' do
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
      client = Bitflyer.realtime_client('key', 'secret')
      ready = spy('ready callback')
      disconnected = spy('disconnected callback')
      client.ready = ready
      client.disconnected = disconnected

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
      expect(WebSocket::Client::Simple).to have_received(:connect).once
    end

    it 'signals readiness after authentication succeeds' do
      client = Bitflyer.realtime_client('key', 'secret')
      ready = spy('ready callback')
      client.ready = ready

      receive_frame('0{}')
      expect(ready).not_to have_received(:call)
      receive_frame('430[null]')

      expect(ready).to have_received(:call).once
      expect(socket).not_to have_received(:close)
    end

    it 'reports authentication rejection once when closing the socket fails' do
      client = Bitflyer.realtime_client('key', 'secret')
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

      handlers.fetch(:error).call(reset)
      handlers.fetch(:close).call(reset)
      expect(disconnected).to have_received(:call).once
      expect(WebSocket::Client::Simple).to have_received(:connect).once
    end

    def receive_frame(data)
      handlers.fetch(:message).call(double(data: data))
    end
  end
end
