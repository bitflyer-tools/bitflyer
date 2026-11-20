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

  it 'forwards subscription failure callbacks to the websocket client' do
    failure_callback = ->(_channel, _error) {}
    expect(websocket_client).to receive(:subscription_failed=).with(failure_callback)

    client.subscription_failed = failure_callback
  end

  describe 'channel mapping' do
    {
      board_snapshot_btc_jpy: :lightning_board_snapshot_BTC_JPY,
      board_eth_btc: :lightning_board_ETH_BTC,
      ticker_btcjpy_mat1wk: :lightning_ticker_BTCJPY_MAT1WK,
      executions_fx_btc_jpy: :lightning_executions_FX_BTC_JPY,
      child_order_events: :child_order_events,
      parent_order_events: :parent_order_events
    }.each do |setter, channel|
      it "subscribes #{setter}= to #{channel} with the assigned callback" do
        expect(websocket_client).to receive(:subscribe).with(channel_name: channel) do |&block|
          expect(block).to equal(callback)
        end

        described_class.new.public_send("#{setter}=", callback)
      end
    end
  end
end
