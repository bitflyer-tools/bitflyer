# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::OrderBook do
  let(:transport) { instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, close_for_shutdown: nil) }
  let(:events) { {} }
  let(:client) { Bitflyer.realtime_client }
  let(:book) { client.order_book(product_code: 'BTC_JPY') }
  let(:delta) { 'lightning_board_BTC_JPY' }
  let(:snapshot) { 'lightning_board_snapshot_BTC_JPY' }

  before do
    stub_transport(transport, events)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
    allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
    client
  end

  after { client.shutdown }

  def stub_transport(socket, handlers)
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(socket).to receive(:connect) { handlers.fetch(:open).call }
  end

  def frame(data, handlers = events)
    handlers.fetch(:message).call(double(data: data))
  end

  def board(channel, bids: [], asks: [], handlers: events)
    sides = { bids: bids, asks: asks }.transform_values do |levels|
      levels.map { |price, size| { price: price, size: size } }
    end
    frame("42#{[channel, sides].to_json}", handlers)
  end

  it 'waits for a snapshot, then applies absolute sizes and removes zero-size levels in delivery order' do
    expect(book).to equal(client.order_book(product_code: 'BTC_JPY'))
    frame('0{}')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_board_BTC_JPY"]').once
    expect(transport).to have_received(:send).with('422["subscribe","lightning_board_snapshot_BTC_JPY"]').once

    board(delta, bids: [[7, 1]])
    expect(book).not_to be_ready
    expect(book.current).to be_nil
    board(snapshot, bids: [[8, 1], [9, 2]], asks: [[12, 3], [10, 4]])
    view = book.current
    expect(book).to be_ready
    expect(view.bids.map(&:price)).to eq([9, 8])
    expect(view.asks.map(&:price)).to eq([10, 12])
    expect(view.best_bid.size).to eq(2)
    expect(view.best_ask.size).to eq(4)
    expect(view.spread).to eq(1)
    expect(view.bids).to be_frozen
    expect(view.best_bid).to be_frozen

    board(delta, bids: [[9.0, 0], [8, 5], [0, 10]], asks: [[10, 0], [11, 2], [0, 3]])
    expect(book.current.bids.map { |level| [level.price, level.size] }).to eq([[8, 5]])
    expect(book.current.asks.map(&:price)).to eq([11, 12])
    expect(view.bids.map(&:price)).to eq([9, 8])

    board(snapshot, asks: [[13, 1]])
    expect(book.current.bids).to be_empty
    expect(book.current.asks.map(&:price)).to eq([13])
    expect(book.current.spread).to be_nil
  end

  it 'invalidates before notifying disconnect and waits for a new snapshot on the replacement connection' do
    book
    frame('0{}')
    board(snapshot, bids: [[8, 1]])
    at_disconnect = []
    client.disconnected = ->(_error) { at_disconnect << book.current }
    events.fetch(:close).call(nil)
    expect(at_disconnect).to eq([nil])
    board(snapshot, bids: [[9, 1]])
    expect(book.current).to be_nil

    replacement = instance_double(Bitflyer::Realtime::Transport, send: nil, close_for_shutdown: nil)
    replacement_events = {}
    stub_transport(replacement, replacement_events)
    allow(transport).to receive(:closed?).and_return(true)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
    client.websocket_client.reconnect
    frame('0{}', replacement_events)
    expect(replacement).to have_received(:send).with('421["subscribe","lightning_board_BTC_JPY"]').once
    expect(replacement).to have_received(:send).with('422["subscribe","lightning_board_snapshot_BTC_JPY"]').once
    board(delta, bids: [[9, 1]], handlers: replacement_events)
    board(snapshot, bids: [[9, 1]])
    expect(book.current).to be_nil

    board(snapshot, asks: [[10, 1]], handlers: replacement_events)
    expect(book.current.bids).to be_empty
    expect(book.current.best_ask.price).to eq(10)
    client.shutdown
    expect(book.current).to be_nil
  end

  it 'keeps product books separate and preserves raw callbacks on the same channels' do
    frame('0{}')
    raw = spy('raw board callback')
    client.board_snapshot_btc_jpy = ->(message) { raw.call(message) }
    book
    eth = client.order_book(product_code: 'ETH_JPY')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_board_snapshot_BTC_JPY"]').once

    board(snapshot, bids: [[8, 1]])
    expect(raw).to have_received(:call).once
    expect(eth).not_to be_ready
    client.unsubscribe(snapshot)
    board(snapshot, bids: [[9, 1]])
    board('lightning_board_snapshot_ETH_JPY', bids: [[6, 1]])
    expect(raw).to have_received(:call).once
    expect(book.current.best_bid.price).to eq(9)
    expect(eth.current.best_bid.price).to eq(6)
  end
end
