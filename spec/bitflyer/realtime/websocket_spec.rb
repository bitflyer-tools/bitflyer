# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:original_socket) { instance_double(WebSocket::Client::Simple::Client) }
  let(:replacement_socket) { instance_double(WebSocket::Client::Simple::Client) }
  let(:message_handlers) { {} }

  before do
    [original_socket, replacement_socket].each do |socket|
      allow(socket).to receive(:on) do |event, &handler|
        message_handlers[socket] = handler if event == :message
      end
    end
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(original_socket, replacement_socket)
    allow(Thread).to receive(:new)
  end

  it 'waits for setup before checking the replacement socket heartbeat' do
    allow(Time).to receive(:now).and_return(Time.at(0))
    client = described_class.new(host: 'wss://example.test', key: nil, secret: nil)
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    message_handlers.fetch(original_socket).call(setup)

    allow(Time).to receive(:now).and_return(Time.at(3))
    expect(original_socket).to receive(:close)
    client.wait_pong

    allow(original_socket).to receive(:open?).and_return(false)
    client.reconnect
    expect(replacement_socket).not_to receive(:send)
    expect(replacement_socket).not_to receive(:close)
    client.wait_pong
    client.send_ping
  end

  it 'closes the replacement socket when its own heartbeat times out after setup' do
    allow(Time).to receive(:now).and_return(Time.at(0))
    client = described_class.new(host: 'wss://example.test', key: nil, secret: nil)
    client.connect
    setup = Struct.new(:data).new('0{"pingInterval":1000,"pingTimeout":1000}')
    message_handlers.fetch(replacement_socket).call(setup)

    allow(Time).to receive(:now).and_return(Time.at(3))
    expect(replacement_socket).to receive(:close)
    client.wait_pong
  end
end
