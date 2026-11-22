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
end
