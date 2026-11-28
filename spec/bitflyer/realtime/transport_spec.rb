# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'timeout'

RSpec.describe Bitflyer::Realtime::Transport do
  subject(:transport) { described_class.new }

  let(:socket) { instance_double(TCPSocket, close: nil) }
  let(:output) { StringIO.new(''.b) }
  let(:server) { WebSocket::Driver.server(output) }
  let(:events) { [] }
  let(:response) { Queue.new }

  before do
    allow(transport).to receive(:connect_tls).and_return(socket)
    server.on(:connect) { server.start }
    allow(socket).to receive(:write) do |request|
      server.parse(request)
      response << drain_output
    end
    transport.on(:open) { events << :open }
    transport.on(:message) { |message| events << message.data }
    transport.on(:close) { |error| events << [:close, error] }
  end

  after { transport.close_for_shutdown }

  def drain_output
    output.string.dup.tap do
      output.truncate(0)
      output.rewind
    end
  end

  def frame(payload)
    server.text(payload)
    drain_output
  end

  def receive_chunks(&chunks)
    pending = []
    allow(socket).to receive(:readpartial).with(16 * 1024) do
      pending = chunks.call(response.pop(true)) unless response.empty?
      pending.shift || raise(EOFError)
    end
    Timeout.timeout(2) do
      transport.connect('wss://example.test')
      transport.thread.join
    end
  end

  it 'delivers a 100 KiB payload in seven reads after the upgrade' do
    payload = 'x' * (100 * 1024)
    receive_chunks do |upgrade|
      data = frame(payload)
      [upgrade] + (0...data.bytesize).step(16 * 1024).map { |offset| data.byteslice(offset, 16 * 1024) }
    end

    expect(socket).to have_received(:readpartial).exactly(9).times # Upgrade, seven frame reads, EOF.
    expect(events).to eq([:open, payload, [:close, nil]])
    expect(socket).to have_received(:write).once
    expect(socket).to have_received(:close).once
    expect(transport).to be_closed
  end

  it 'preserves frames across the upgrade boundary and drains each chunk in order' do
    receive_chunks do |upgrade|
      first = frame('first')
      [upgrade.byteslice(0...-1), upgrade.byteslice(-1, 1) + first.byteslice(0, 1),
       first.byteslice(1..) + frame('second') + frame("third \n")]
    end

    expect(events).to eq([:open, 'first', 'second', "third \n", [:close, nil]])
  end

  context 'with the realtime client' do
    let(:incoming) { Queue.new }
    let(:reconnects) { Queue.new }
    let(:replacement) { described_class.new }
    let(:snapshots) { Queue.new }
    let(:disconnects) { Queue.new }
    let(:channel) { :lightning_board_snapshot_BTC_JPY }
    let(:limit) { described_class::MAX_MESSAGE_SIZE }

    before do
      allow(described_class).to receive(:new).and_return(transport, replacement)
      allow(replacement).to receive(:connect) { |url| reconnects << url }
      allow(socket).to receive(:readpartial).with(described_class::READ_SIZE) { incoming.pop || raise(EOFError) }
      allow(socket).to receive(:close) { incoming << nil }
      allow(JSON).to receive(:parse).and_call_original

      @client = Bitflyer::Realtime::WebSocketClient.new(host: 'wss://example.test', key: nil, secret: nil)
      @client.disconnected = ->(error) { disconnects << error }
      @client.subscribe(channel_name: channel) { |snapshot| snapshots << snapshot }
      incoming << response.pop(timeout: 5)
      enqueue_frame(0x81, '0{}')
      enqueue_frame(0x81, '431[null]')
    end

    after do
      @client&.shutdown
      transport.thread&.join(5)
    end

    def enqueue_frame(first_byte, payload)
      length = payload.bytesize
      header = length <= 125 ? [first_byte, length].pack('CC') : [first_byte, 127, length].pack('CCQ>')
      bytes = header + payload.b
      (0...bytes.bytesize).step(described_class::READ_SIZE) do |offset|
        incoming << bytes.byteslice(offset, described_class::READ_SIZE)
      end
    end

    { single: false, fragmented: true }.each do |kind, fragmented|
      it "delivers a snapshot at the limit and reconnects after rejecting a #{kind} oversized message" do
        snapshot = { 'mid_price' => 10_000, 'bids' => [{ 'price' => 9900, 'size' => 0.5 }], 'asks' => [] }
        packet = "42#{JSON.generate([channel, snapshot])}".ljust(limit)
        enqueue_frame(0x81, packet)
        expect(snapshots.pop(timeout: 5)).to eq(snapshot)

        oversized = packet + ' '
        if fragmented
          enqueue_frame(0x01, packet)
          enqueue_frame(0x80, ' ')
        else
          enqueue_frame(0x81, oversized)
        end

        expect(disconnects.pop(timeout: 5)).to be_a(WebSocket::Driver::ProtocolError)
          .and have_attributes(message: /length too large/)
        expect(reconnects.pop(timeout: 5)).to eq('wss://example.test/socket.io/?transport=websocket')
        expect(JSON).not_to have_received(:parse).with(oversized.delete_prefix('42'))
        expect(snapshots).to be_empty
      end
    end
  end
end
