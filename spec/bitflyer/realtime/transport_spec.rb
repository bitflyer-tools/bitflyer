# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Bitflyer::Realtime::Transport do
  subject(:transport) { described_class.new }

  let(:socket) { instance_double(TCPSocket, close: nil) }
  let(:events) { [] }
  let(:response) { Queue.new }

  before do
    allow(TCPSocket).to receive(:new).and_return(socket)
    allow(socket).to receive(:write) do |request|
      handshake = WebSocket::Handshake::Server.new
      handshake << request
      response << handshake.to_s.b
    end
    received = events
    transport.on(:open) { received << :open }
    transport.on(:message) { |message| received << message.data }
    transport.on(:error) { |error| received << error }
    transport.on(:close) { received << :close }
  end

  after { transport.close_for_shutdown }

  def frame(payload)
    WebSocket::Frame::Outgoing::Server.new(version: 13, type: :text, data: payload).to_s.b
  end

  def receive_chunks(&chunks)
    pending = []
    allow(socket).to receive(:readpartial).with(16 * 1024) do
      pending = chunks.call(response.pop(true)) unless response.empty?
      pending.shift || raise(EOFError)
    end
    Timeout.timeout(2) do
      transport.connect('ws://example.test')
      transport.thread.join
    end
  end

  it 'delivers a 100 KiB payload in seven reads after the upgrade' do
    payload = 'x' * (100 * 1024)
    data = frame(payload)
    receive_chunks do |upgrade|
      [upgrade] + (0...data.bytesize).step(16 * 1024).map { |offset| data.byteslice(offset, 16 * 1024) }
    end

    expect(socket).to have_received(:readpartial).exactly(9).times # Upgrade, seven frame reads, EOF.
    expect(events).to eq([:open, payload, :close])
    expect(socket).to have_received(:close).once
    expect(transport).to be_closed
  end

  it 'preserves frames across the upgrade boundary and drains each chunk in order' do
    first = frame('first')
    receive_chunks do |upgrade|
      [upgrade.byteslice(0...-1), upgrade.byteslice(-1, 1) + first.byteslice(0, 1),
       first.byteslice(1..) + frame('second') + frame("third \n")]
    end

    expect(events).to eq([:open, 'first', 'second', "third \n", :close])
  end
end
