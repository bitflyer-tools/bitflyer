# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::Realtime::Client do
  describe 'channel mapping' do
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

  describe 'setter return values' do
    let(:client) { described_class.new('key', 'secret') }
    let(:socket) do
      instance_double(Bitflyer::Realtime::Transport, open?: true, send: nil, close: nil, close_on_eof: nil)
    end
    let(:handlers) { {} }
    let(:callback) { ->(_message) {} }

    before do
      allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
      allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
      allow(socket).to receive(:connect) { handlers.fetch(:open).call }
      allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)

      client.websocket_client.setup_by_response(json: '{}')
      client.websocket_client.authenticated(json: '[null]')
    end

    after { client.shutdown }

    it 'returns the callback from a direct public event setter call' do
      expect(socket).to receive(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').and_return(:transport_return)

      expect(client.public_send(:ticker_btc_jpy=, callback)).to equal(callback)
      expect(client.websocket_client.channel_callbacks.fetch(:lightning_ticker_BTC_JPY)).to equal(callback)
    end

    it 'returns the callback from a direct private event setter call' do
      expect(socket).to receive(:send).with('42["subscribe","child_order_events"]').and_return(nil)

      expect(client.public_send(:child_order_events=, callback)).to equal(callback)
      expect(client.websocket_client.channel_callbacks.fetch(:child_order_events)).to equal(callback)
    end
  end
end
