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
    let(:socket) { instance_double(WebSocket::Client::Simple::Client, on: nil, close: nil) }
    let(:client) { Bitflyer.realtime_client }
    let(:session) { client.websocket_client }
    let(:connected_at) { Time.at(1_000) }

    before do
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
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

    context 'with credentials' do
      let(:client) { Bitflyer.realtime_client('test_api_key', 'test_api_secret') }

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
