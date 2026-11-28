# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'

RSpec.describe Bitflyer::Realtime::WebSocketClient, 'with a silent TLS peer' do
  before do
    stub_const('Bitflyer::Realtime::ConnectionAttempt::TIMEOUT', 1)
    @server = TCPServer.new('127.0.0.1', 0)
  end

  after do
    @client&.shutdown
    @retry_peer&.close
    @server.close
  end

  def connect_to_server
    @client = described_class.new(host: "wss://127.0.0.1:#{@server.addr[1]}", key: nil, secret: nil)
  end

  def read_until_client_closes
    peer = @server.accept
    peer.read
  ensure
    peer&.close
  end

  it 'returns from construction and closes the socket when the TLS handshake stalls' do
    data = Timeout.timeout(5) do
      connect_to_server
      read_until_client_closes
    end

    expect(data.getbyte(0)).to eq(22) # TLS handshake record
    expect(@client.websocket_client).to be_nil
  end

  it 'closes a stalled reconnect socket and makes another connection attempt' do
    Timeout.timeout(8) do
      connect_to_server
      expect(read_until_client_closes.getbyte(0)).to eq(22)

      expect(read_until_client_closes.getbyte(0)).to eq(22)
      @retry_peer = @server.accept
      expect(@retry_peer.read(1)&.getbyte(0)).to eq(22)
    end
  end
end
