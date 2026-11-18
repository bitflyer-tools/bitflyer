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
    let(:socket) { instance_double(WebSocket::Client::Simple::Client, on: nil, close: nil) }
    let(:client) { Bitflyer.realtime_client }
    let(:session) { client.websocket_client }
    let(:connected_at) { Time.at(1_000) }

    before do
      allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
      allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
      allow(Time).to receive(:now).and_return(connected_at)
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond).and_return(10_000)
    end

    it 'returns a Realtime::Client instance' do
      expect(client).to be_a(Bitflyer::Realtime::Client)
    end

    it 'exposes heartbeat state initialized and updated by the WebSocket session' do
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
