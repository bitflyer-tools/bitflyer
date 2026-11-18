# frozen_string_literal: true

require 'spec_helper'

describe 'Realtime ready notifications' do
  let(:transport) { double('websocket') }
  let(:handlers) { {} }
  let(:notifications) { Queue.new }
  let(:callback) { -> { notifications << :ready } }

  before do
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(transport)
    allow(transport).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
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
    allow(transport).to receive(:on).with(:message) do |_, &handler|
      handler.call(Struct.new(:data).new('0{}'))
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

    allow(transport).to receive(:open?).and_return(false)
    client.websocket_client.reconnect
    receive_message('0{}')

    expect(notifications.size).to eq(2)
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
end
