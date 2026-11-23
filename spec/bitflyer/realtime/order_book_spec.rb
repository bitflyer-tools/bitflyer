# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

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
    expect(view.bids[0]).to equal(view.best_bid)
    expect(view.asks.fetch(0)).to equal(view.best_ask)
    expect { view.bids.clear }.to raise_error(FrozenError)
    expect { view.asks.clear }.to raise_error(FrozenError)
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

  it 'reuses the top after unrelated deltas without scanning either side' do
    book
    frame('0{}')
    frame('431[null]')
    board(snapshot, bids: [[8, 1], [9, 2]], asks: [[12, 3], [10, 4]])
    top = book.top_of_book

    %i[@bids @asks].each do |name|
      side = book.instance_variable_get(name)
      %i[each each_key each_value keys values].each { |method| expect(side).not_to receive(method) }
    end
    board(delta, bids: [[8, 5]])
    expect(book.top_of_book).to equal(top)
    board(delta, asks: [[12, 6]])
    expect(book.top_of_book).to equal(top)
  end

  it 'reads immutable best levels after deltas and snapshot replacement without building sorted depth' do
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

    board(delta, bids: [[7, 1], [9, 2]], asks: [[9.5, 3]])
    improved = book.top_of_book
    expect([improved.best_bid.price, improved.best_ask.price, improved.spread]).to eq([9, 9.5, 0.5])
    expect(improved.best_bid).to be_frozen
    expect(improved.best_ask).to be_frozen

    board(delta, bids: [[11, 2], [11.0, 0], [9, 0], [7, 4]], asks: [[9.5, 0]])
    replacement = book.top_of_book
    expect([replacement.best_bid.price, replacement.best_bid.size, replacement.best_ask.price]).to eq([7, 4, 10])
    expect([improved.best_bid.price, improved.best_ask.price]).to eq([9, 9.5])

    board(snapshot, asks: [[15, 2]])
    top = book.top_of_book
    expect(top.best_bid).to be_nil
    expect(top.best_ask.price).to eq(15)
    expect(top.spread).to be_nil
  end

  it 'delivers raw deltas in order while an invalidated book waits for a valid snapshot' do
    book
    raw = Queue.new
    client.subscribe(delta) { |message| raw << message }
    frame('0{}')
    frame('431[null]')
    frame('432[null]')
    board(snapshot, bids: [[100, 1]], asks: [[110, 1]])
    expect(book).to be_ready

    malformed = { bids: [{ price: 105, size: 1 }], asks: [{}] }
    expect { frame("42#{[delta, malformed].to_json}") }.to output(/key not found: "price"/).to_stdout
    expect(book).not_to be_ready
    expect(book.current).to be_nil

    board(delta, bids: [[106, 1]])
    expect(book).not_to be_ready
    expect(book.current).to be_nil
    expect(raw.pop(timeout: 5)).to eq(JSON.parse(malformed.to_json))
    expect(raw.pop(timeout: 5)).to eq('bids' => [{ 'price' => 106, 'size' => 1 }], 'asks' => [])

    expect { frame("42#{[snapshot, malformed].to_json}") }.to output(/key not found: "price"/).to_stdout
    expect(book.current).to be_nil

    board(snapshot, bids: [[101, 1]], asks: [[111, 1]])
    expect(book).to be_ready
    expect(book.current.bids.map(&:price)).to eq([101])
    expect(book.current.asks.map(&:price)).to eq([111])

    board(delta, bids: [[102, 2]])
    expect(book.current.best_bid.price).to eq(102)
    expect(raw.pop(timeout: 5)).to eq('bids' => [{ 'price' => 102, 'size' => 2 }], 'asks' => [])
  end

  %i[bids asks].each do |side|
    it "rejects an empty object in #{side} until a valid snapshot arrives" do
      book
      frame('0{}')
      frame('431[null]')

      [snapshot, delta].each do |channel|
        board(snapshot, bids: [[100, 1]], asks: [[110, 1]])
        expect(book.current.best_bid.price).to eq(100)
        expect(book.top_of_book.best_ask.price).to eq(110)
        malformed = { bids: [{ price: 105, size: 1 }], asks: [{ price: 115, size: 1 }] }
        malformed[side] = {}

        expect { frame("42#{[channel, malformed].to_json}") }
          .to output(/Order book sides must be arrays/).to_stdout
        expect(book).not_to be_ready
        expect(book.current).to be_nil
        expect(book.top_of_book).to be_nil

        board(delta, bids: [[106, 1]])
        expect(book).not_to be_ready

        board(snapshot)
        expect(book).to be_ready
        expect(book.current.bids).to be_empty
        expect(book.current.asks).to be_empty
        board(delta)
        expect(book).to be_ready
      end
    end
  end

  {
    'an overflowing price' => '{"price":1e309,"size":1}',
    'an overflowing size' => '{"price":100,"size":1e309}',
    'a negative price' => '{"price":-100,"size":1}',
    'a negative size' => '{"price":100,"size":-1}',
    'a negative size at a zero price' => '{"price":0,"size":-1}',
    'a string price' => '{"price":"100","size":1}',
    'a null size' => '{"price":100,"size":null}'
  }.each do |description, invalid_level|
    it "rejects #{description} in snapshots and deltas and recovers on a valid snapshot" do
      book
      frame('0{}')
      frame('431[null]')

      [snapshot, delta].each do |channel|
        board(snapshot, bids: [[99, 1.5]])
        expect(book.current.best_bid.size).to eq(1.5)
        expect(book.top_of_book.best_bid.price).to eq(99)
        invalid_board = %({"bids":[{"price":101,"size":2}],"asks":[#{invalid_level}]})

        expect { frame(%(42["#{channel}",#{invalid_board}])) }
          .to output(/price and size must be finite non-negative numbers/).to_stdout
        expect(book).not_to be_ready
        expect(book.current).to be_nil
        expect(book.top_of_book).to be_nil

        board(delta, bids: [[102, 2]])
        expect(book).not_to be_ready
      end

      board(snapshot, bids: [[103.5, 0.5]])
      expect(book).to be_ready
      expect(book.current.bids.map(&:price)).to eq([103.5])
      board(delta, bids: [[103.5, 0.0], [0, 1]])
      expect(book.current.bids).to be_empty
    end
  end

  it 'invalidates before notifying disconnect and waits for a new snapshot on the replacement connection' do
    book
    frame('0{}')
    frame('431[null]')
    board(snapshot, bids: [[8, 1]])
    expect(book.top_of_book.best_bid.price).to eq(8)
    at_disconnect = Queue.new
    client.disconnected = ->(_error) { at_disconnect << [book.current, book.top_of_book] }
    events.fetch(:close).call(nil)
    expect(Timeout.timeout(5) { at_disconnect.pop }).to eq([nil, nil])
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

  %i[delta snapshot].each do |feed|
    %i[rejected timed_out].each do |failure|
      it "retries only the #{failure.to_s.tr('_', ' ')} #{feed} feed through order_book" do
        failed_channel = public_send(feed)
        failed_id, acknowledged_id = feed == :delta ? [1, 2] : [2, 1]
        raw = Queue.new
        websocket = client.websocket_client
        frame('0{}')
        book
        client.subscribe(failed_channel) { |message| raw << message }
        callbacks = websocket.channel_callbacks
        frame("43#{acknowledged_id}[null]")
        if failure == :rejected
          frame("43#{failed_id}#{['subscription rejected'].to_json}")
        else
          allow(transport).to receive(:open?).and_return(true)
          allow(websocket).to receive(:monotonic_milliseconds)
            .and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) + 10_000)
          websocket.send(:expire_runtime_subscriptions, transport)
        end

        expect(client.order_book(product_code: 'BTC_JPY')).to equal(book)
        expect(client.order_book(product_code: 'BTC_JPY')).to equal(book)
        expect(transport).to have_received(:send).with("423#{['subscribe', failed_channel].to_json}").once
        frame('433[null]')
        expect(client.order_book(product_code: 'BTC_JPY')).to equal(book)
        expect(websocket.channel_callbacks).to eq(callbacks)
        expect(transport).to have_received(:send).with(/\A42\d+\["subscribe",/).exactly(3).times

        expect(book).not_to be_ready
        board(snapshot, bids: [[8, 1]])
        expect(book).to be_ready
        board(delta, bids: [[8, 2]])
        expect(book.current.best_bid.size).to eq(2)
        expect(raw.pop(timeout: 5).fetch('bids')).to eq([{ 'price' => 8, 'size' => feed == :delta ? 2 : 1 }])
      end
    end
  end
end
