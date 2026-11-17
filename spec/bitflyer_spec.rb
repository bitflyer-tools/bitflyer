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
    let(:transport) { instance_double(WebSocket::Client::Simple::Client, send: nil, open?: false) }
    let(:handlers) { {} }

    before do
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(transport)
      allow(transport).to receive(:on) { |event, &handler| handlers[event] = handler }
      allow(transport).to receive(:close) { handlers.fetch(:close).call(nil) }
      allow(Thread).to receive(:new)
    end

    it 'returns a Realtime::Client instance' do
      client = Bitflyer.realtime_client
      expect(client).to be_a(Bitflyer::Realtime::Client)
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

      expect(transport).to have_received(:close).once
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
      expect(transport).not_to have_received(:close)
    end

    def receive_frame(data)
      handlers.fetch(:message).call(double(data: data))
    end
  end
end
