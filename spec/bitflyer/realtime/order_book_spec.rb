# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::OrderBook do
  let(:transport) { instance_double(Bitflyer::Realtime::Transport, send: nil, closed?: false, reconnectable?: false, close_for_shutdown: nil) }
  let(:events) { {} }
  let(:client) { Bitflyer.realtime_client }
  let(:book) { client.order_book(product_code: 'BTC_JPY') }
  let(:delta) { 'lightning_board_BTC_JPY' }
  let(:snapshot) { 'lightning_board_snapshot_BTC_JPY' }

  before do
    stub_transport(transport, events)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(transport)
    allow_any_instance_of(Bitflyer::Realtime::WebSocketClient).to receive(:start_monitoring)
  end

  after { client.shutdown }

  def stub_transport(socket, handlers)
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(socket).to receive(:connect) { handlers.fetch(:open).call }
  end

  def frame(data, handlers = events)
    client
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
    frame('431[null]')

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
    expect(view).to be_frozen
    expect(view.bids).to be_frozen
    expect(view.asks).to be_frozen
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

  it 'reads the best levels after deltas without building sorted depth' do
    book
    frame('0{}')
    frame('431[null]')
    expect(book.top_of_book).to be_nil
    board(snapshot, bids: [[8, 1], [9, 2]], asks: [[12, 3], [10, 4]])
    before_delta = book.top_of_book

    expect(book).not_to receive(:sorted_levels)
    board(delta, bids: [[9.0, 0]])
    top = book.top_of_book
    expect([top.best_bid.price, top.best_ask.price, top.spread]).to eq([8, 10, 2])
    expect(top).to be_frozen
    expect(before_delta.best_bid.price).to eq(9)

    board(delta, asks: [[10, 6]])
    expect(book.top_of_book.best_ask.size).to eq(6)
    expect(top.best_ask.size).to eq(4)

    board(delta, bids: [[8, 0]])
    top = book.top_of_book
    expect(top.best_bid).to be_nil
    expect(top.best_ask.price).to eq(10)
    expect(top.spread).to be_nil
  end

  it 'invalidates after a malformed delta and waits for a valid snapshot' do
    book
    frame('0{}')
    frame('431[null]')
    board(snapshot, bids: [[100, 1]], asks: [[110, 1]])
    expect(book).to be_ready

    malformed = { bids: [{ price: 105, size: 1 }], asks: [{}] }
    expect { frame("42#{[delta, malformed].to_json}") }.to output(/key not found: "price"/).to_stdout
    expect(book).not_to be_ready
    expect(book.current).to be_nil

    board(delta, bids: [[106, 1]])
    expect(book).not_to be_ready
    expect(book.current).to be_nil

    expect { frame("42#{[snapshot, malformed].to_json}") }.to output(/key not found: "price"/).to_stdout
    expect(book.current).to be_nil

    board(snapshot, bids: [[101, 1]], asks: [[111, 1]])
    expect(book).to be_ready
    expect(book.current.bids.map(&:price)).to eq([101])
    expect(book.current.asks.map(&:price)).to eq([111])

    board(delta, bids: [[102, 2]])
    expect(book.current.best_bid.price).to eq(102)
  end

  it 'invalidates before notifying disconnect and waits for a new snapshot on the replacement connection' do
    book
    frame('0{}')
    frame('431[null]')
    board(snapshot, bids: [[8, 1]])
    expect(book.top_of_book.best_bid.price).to eq(8)
    at_disconnect = []
    client.disconnected = ->(_error) { at_disconnect << [book.current, book.top_of_book] }
    events.fetch(:close).call(nil)
    expect(at_disconnect).to eq([[nil, nil]])
    board(snapshot, bids: [[9, 1]])
    expect(book.current).to be_nil

    replacement = instance_double(Bitflyer::Realtime::Transport, send: nil, close_for_shutdown: nil)
    replacement_events = {}
    stub_transport(replacement, replacement_events)
    allow(transport).to receive(:reconnectable?).and_return(true)
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(replacement)
    client.websocket_client.reconnect
    frame('0{}', replacement_events)
    expect(replacement).to have_received(:send).with('421["subscribe","lightning_board_BTC_JPY"]').once
    expect(replacement).to have_received(:send).with('422["subscribe","lightning_board_snapshot_BTC_JPY"]').once
    board(snapshot, bids: [[9, 1]], handlers: replacement_events)
    expect(book.current).to be_nil
    frame('431[null]', replacement_events)
    board(delta, bids: [[9, 1]], handlers: replacement_events)
    board(snapshot, bids: [[9, 1]])
    expect(book.current).to be_nil

    board(snapshot, asks: [[10, 1]], handlers: replacement_events)
    expect(book.current.bids).to be_empty
    expect(book.current.best_ask.price).to eq(10)
    expect(book.top_of_book.best_ask.price).to eq(10)
    client.shutdown
    expect(book.top_of_book).to be_nil
    expect(book.current).to be_nil
  end

  it 'waits for the delta acknowledgement while an existing snapshot callback keeps receiving updates' do
    frame('0{}')
    raw = Queue.new
    client.board_snapshot_btc_jpy = ->(message) { raw << message }
    book
    eth = client.order_book(product_code: 'ETH_JPY')
    expect(transport).to have_received(:send).with('421["subscribe","lightning_board_snapshot_BTC_JPY"]').once
    frame('431[null]')

    board(snapshot, bids: [[8, 1]])
    expect(raw.pop(timeout: 5).fetch('bids')).to eq([{ 'price' => 8, 'size' => 1 }])
    expect(book.current).to be_nil
    frame('432[null]')
    expect(book.current).to be_nil

    board(snapshot, bids: [[9, 1]])
    board(delta, bids: [[9, 4]])
    expect(book.current.best_bid.size).to eq(4)
    expect(raw.pop(timeout: 5).fetch('bids')).to eq([{ 'price' => 9, 'size' => 1 }])
    board('lightning_board_snapshot_ETH_JPY', bids: [[6, 1]])
    expect(eth).not_to be_ready

    drained = Queue.new
    client.ticker_btc_jpy = ->(_message) { drained << true }
    client.unsubscribe(snapshot)
    board(snapshot, bids: [[10, 1]])
    frame('433[null]')
    board('lightning_board_snapshot_ETH_JPY', bids: [[6, 1]])
    frame('42["lightning_ticker_BTC_JPY",{}]')
    expect(drained.pop(timeout: 5)).to be(true)
    expect(raw).to be_empty
    expect(book.current.best_bid.price).to eq(10)
    expect(eth.current.best_bid.price).to eq(6)
  end

  it 'keeps applying board updates while the callback queue is full' do
    stub_const('Bitflyer::Realtime::WebSocketClient::CALLBACK_QUEUE_LIMIT', 1)
    started = Queue.new
    release = Queue.new
    client.ticker_btc_jpy = lambda do |_message|
      started << true
      release.pop
    end
    client.subscribe(delta) { |_message| }
    book
    frame('0{}')
    frame('431[null]')
    board(snapshot, bids: [[8, 1]])
    frame('42["lightning_ticker_BTC_JPY",{}]')
    expect(started.pop(timeout: 5)).to be(true)

    board(delta, bids: [[8, 2]])
    board(delta, bids: [[8, 3]])

    expect(book.current.best_bid.size).to eq(3)
  ensure
    release.close
  end

  it 'keeps the book uninitialized when the delta subscription is rejected' do
    book
    frame('0{}')
    frame('431["subscription rejected"]')
    frame('432[null]')
    board(snapshot, bids: [[8, 1]])
    expect(book.current).to be_nil
  end

  it 'retries rejected board subscriptions on the same connection without duplicating requests' do
    book
    frame('0{}')
    client.subscribe(delta) { |_message| }
    client.subscribe(snapshot) { |_message| }
    frame('431["subscription rejected"]')
    frame('432["subscription rejected"]')

    client.subscribe(delta) { |_message| }
    client.subscribe(snapshot) { |_message| }
    client.subscribe(delta) { |_message| }
    client.subscribe(snapshot) { |_message| }
    frame('433[null]')
    frame('434[null]')

    raw = Queue.new
    client.subscribe(delta) { |message| raw << message }
    client.subscribe(snapshot) { |_message| }
    [delta, snapshot].each do |channel|
      expect(transport).to have_received(:send).with(/\A42\d+\["subscribe","#{channel}"\]\z/).twice
    end
    board(snapshot, bids: [[8, 1]])
    board(delta, bids: [[8, 2]])
    expect(book.current.best_bid.size).to eq(2)
    expect(raw.pop(timeout: 5).fetch('bids')).to eq([{ 'price' => 8, 'size' => 2 }])
  end
end
