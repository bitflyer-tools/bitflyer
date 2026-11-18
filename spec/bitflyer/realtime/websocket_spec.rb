# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  subject(:client) { described_class.new(host: 'wss://example.test', key: key, secret: secret) }

  let(:socket) { instance_double(WebSocket::Client::Simple::Client, on: nil, send: nil, close: nil) }
  let(:key) { nil }
  let(:secret) { nil }

  before do
    @heartbeat_time = 10_000
    @wall_time = Time.at(1_000)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @heartbeat_time }
    allow(Time).to receive(:now) { @wall_time }
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    client.setup_by_response(json: '{"pingInterval":1500,"pingTimeout":750}')
  end

  it 'sends a ping at each elapsed interval despite wall-clock changes' do
    @wall_time += 60
    @heartbeat_time += 1_499
    client.send_ping
    expect(socket).not_to have_received(:send)

    @wall_time -= 160
    @heartbeat_time += 1
    client.send_ping
    client.send_ping
    expect(socket).to have_received(:send).with('2').once

    @heartbeat_time += 1_500
    client.send_ping
    expect(socket).to have_received(:send).with('2').twice
  end

  it 'closes the socket at the elapsed pong deadline despite wall-clock changes' do
    @wall_time += 60
    @heartbeat_time += 2_249
    client.wait_pong
    expect(socket).not_to have_received(:close)

    @wall_time -= 160
    @heartbeat_time += 1
    client.wait_pong
    expect(socket).to have_received(:close).once
  end

  it 'restarts the pong deadline when a pong is received' do
    @heartbeat_time += 1_500
    client.receive_pong

    @heartbeat_time += 2_249
    client.wait_pong
    expect(socket).not_to have_received(:close)

    @heartbeat_time += 1
    client.wait_pong
    expect(socket).to have_received(:close).once
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
