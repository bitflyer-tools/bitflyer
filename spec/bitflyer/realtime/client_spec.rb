# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::Realtime::Client do
  let(:client) { described_class.new('key', 'secret') }
  let(:socket) { instance_double(Bitflyer::Realtime::Transport, on: nil, connect: nil, close_on_eof: nil, open?: true, send: nil) }
  let(:callback) { ->(_message) {} }

  before do
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
    client.websocket_client.setup_by_response(json: '{}')
    client.websocket_client.authenticated(json: '[null]')
  end

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
