# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::Realtime::Client do
  let(:websocket_client) { instance_double(Bitflyer::Realtime::WebSocketClient) }
  let(:callback) { ->(message) { message } }

  before do
    allow(Bitflyer::Realtime::WebSocketClient).to receive(:new).and_return(websocket_client)
  end

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
