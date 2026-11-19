# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::Realtime::Client do
  let(:client) { described_class.new('key', 'secret') }
  let(:websocket_client) { instance_double(Bitflyer::Realtime::WebSocketClient) }
  let(:callback) { ->(_message) {} }

  before do
    allow(Bitflyer::Realtime::WebSocketClient).to receive(:new).and_return(websocket_client)
  end

  it 'returns the callback from a direct public event setter call' do
    expect(websocket_client).to receive(:subscribe).with(channel_name: :lightning_ticker_BTC_JPY) do |&block|
      expect(block).to equal(callback)
      :transport_return
    end

    expect(client.public_send(:ticker_btc_jpy=, callback)).to equal(callback)
  end

  it 'returns the callback from a direct private event setter call' do
    expect(websocket_client).to receive(:subscribe).with(channel_name: :child_order_events) do |&block|
      expect(block).to equal(callback)
      nil
    end

    expect(client.public_send(:child_order_events=, callback)).to equal(callback)
  end
end
