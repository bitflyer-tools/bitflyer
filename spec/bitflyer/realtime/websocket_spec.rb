# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:socket_class) do
    Class.new do
      attr_accessor :open

      def initialize
        @handlers = {}
      end

      def on(event, &handler)
        @handlers[event] = handler
      end

      def emit(event, payload)
        instance_exec(payload, &@handlers.fetch(event))
      end

      def open?
        @open && !closed?
      end

      def closed?
        !!@closed
      end

      def close
        return if closed?

        @closed = true
        emit(:close, nil)
      end
    end
  end

  let(:original) { socket_class.new }
  let(:replacement) { socket_class.new }
  let(:transport) { WebSocket::Client::Simple }
  let(:client) { described_class.new(host: 'wss://example.com', key: nil, secret: nil) }
  let(:setup_message) { Struct.new(:data).new('0{}') }

  before do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0)
  end

  it 'keeps a pending handshake on the same socket past the first monitor tick' do
    expect(transport).to receive(:connect).once.and_yield(original).and_return(original)
    client.ready = ready = double
    expect(ready).to receive(:call).once

    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(101.0)
    client.reconnect
    original.open = true
    original.emit(:message, setup_message)
    client.reconnect

    expect(client.websocket_client).to equal(original)
    expect(original).not_to be_closed
  end

  it 'closes a timed-out socket before replacing it and ignores its late events' do
    expect(transport).to receive(:connect).ordered.and_yield(original).and_return(original)
    expect(original).to receive(:close).ordered.and_call_original
    expect(transport).to receive(:connect).ordered.and_yield(replacement).and_return(replacement)
    client.ready = ready = double
    client.disconnected = disconnected = double
    expect(ready).to receive(:call).once
    expect(disconnected).not_to receive(:call)

    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(110.0)
    client.reconnect
    original.emit(:message, setup_message)
    original.emit(:error, Errno::ECONNRESET.new)
    original.emit(:close, nil)
    expect(client.last_pong_at).to be_nil

    replacement.open = true
    replacement.emit(:message, setup_message)
    expect(client.websocket_client).to equal(replacement)
  end

  it 'retries a closed socket before its handshake deadline' do
    expect(transport).to receive(:connect).ordered.and_yield(original).and_return(original)
    expect(transport).to receive(:connect).ordered.and_yield(replacement).and_return(replacement)
    client.disconnected = disconnected = double
    expect(disconnected).to receive(:call).with(nil)

    original.close
    client.reconnect

    expect(client.websocket_client).to equal(replacement)
  end
end
