# frozen_string_literal: true

require 'spec_helper'

describe 'Realtime ready notifications' do
  let(:transport) { instance_double(Bitflyer::Realtime::Transport, reconnectable?: false, closed?: false, close_for_shutdown: nil) }
  let(:handlers) { {} }
  let(:notifications) { Queue.new }
  let(:callback) { -> { notifications << :ready } }

  before do
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
    stub_connection(transport)
    allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
  end

  def stub_connection(socket)
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(socket).to receive(:connect) { handlers.fetch(:open).call }
  end

  def receive_message(data)
    handlers.fetch(:message).call(Struct.new(:data).new(data))
  end

  it 'notifies a callback registered before setup once' do
    client = Bitflyer.realtime_client
    client.ready = callback

    expect(notifications.size).to eq(0)
    receive_message('0{}')
    receive_message('0{}')

    expect(notifications.size).to eq(1)
  end

  it 'notifies a callback registered after setup during construction once' do
    allow(transport).to receive(:connect) do
      handlers.fetch(:open).call
      receive_message('0{}')
    end

    client = Bitflyer.realtime_client
    client.ready = callback
    client.ready = callback

    expect(notifications.size).to eq(1)
  end

  it 'notifies once when setup and registration run concurrently and again after reconnect' do
    client = Bitflyer.realtime_client
    start = Queue.new
    workers = [
      Thread.new { start.pop; receive_message('0{}') },
      Thread.new { start.pop; client.ready = callback }
    ]

    workers.each { start << true }
    workers.each(&:value)
    expect(notifications.size).to eq(1)

    handlers.fetch(:close).call(nil)
    client.ready = callback
    expect(notifications.size).to eq(1)

    replacement = instance_double(Bitflyer::Realtime::Transport, closed?: false, close_for_shutdown: nil)
    stub_connection(replacement)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
    allow(transport).to receive(:reconnectable?).and_return(true)
    client.websocket_client.reconnect
    receive_message('0{}')

    expect(notifications.size).to eq(2)
  end

  it 'discards a pending notification on shutdown' do
    client = Bitflyer.realtime_client
    receive_message('0{}')

    client.shutdown
    client.ready = callback

    expect(notifications).to be_empty
  end

  it 'waits for successful authentication before notifying' do
    allow(transport).to receive(:send)
    client = Bitflyer.realtime_client('key', 'secret')
    receive_message('0{}')
    client.ready = callback

    expect(notifications.size).to eq(0)
    receive_message('430[null]')

    expect(notifications.size).to eq(1)
  end

  [nil, Errno::ECONNRESET.new].each do |error|
    it "preserves the replacement socket's pending notification after a stale close with #{error&.class || "EOF"}" do
      replacement = instance_double(Bitflyer::Realtime::Transport, closed?: false, close_for_shutdown: nil)
      stub_connection(replacement)
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport, replacement)
      allow(transport).to receive(:reconnectable?).and_return(true)
      client = Bitflyer.realtime_client
      disconnected = []
      client.disconnected = ->(reason) { disconnected << reason }
      stale_handler = handlers.fetch(:close)

      client.websocket_client.reconnect
      receive_message('0{}')
      stale_handler.call(error)
      client.ready = callback
      client.ready = callback

      expect(notifications.size).to eq(1)
      expect(disconnected).to be_empty
    end
  end
end
