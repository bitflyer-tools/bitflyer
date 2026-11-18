# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) do
    instance_double(Bitflyer::Realtime::Transport, open?: true, closed?: false, send: nil, close: nil,
                    close_on_eof: nil)
  end
  let(:handlers) { {} }

  before do
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(Bitflyer::Realtime::Transport).to receive(:new).and_return(socket)
    allow(socket).to receive(:connect) do
      attempt = @attempts.shift
      raise attempt if attempt

      handlers.fetch(:open).call
    end
    allow($stdout).to receive(:puts)
  end

  after { @client&.shutdown }

  def receive_message(data)
    handlers.fetch(:message).call(double('WebSocket payload', data: data))
  end

  it 'replays subscriptions registered during the initial outage once the session is ready' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    @client = Bitflyer.realtime_client

    events = []
    @client.ticker_btc_jpy = ->(event) { events << event }
    @client.websocket_client.reconnect
    @client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('42["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
  end

  it 'waits for the replacement session before sending new subscriptions' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [nil, nil]
    @client = Bitflyer.realtime_client
    receive_message('0{}')

    allow(socket).to receive(:closed?).and_return(true)
    @client.websocket_client.reconnect
    @client.ticker_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, nil]
    reconnected = Queue.new
    allow(socket).to receive(:close_on_eof) { reconnected << true }

    @client = Bitflyer.realtime_client

    Timeout.timeout(5) { reconnected.pop }
    expect(socket).to have_received(:connect).exactly(3).times
    expect(@client.websocket_client.websocket_client).to eq(socket)
  end

  it 'waits for authentication before replaying private subscriptions' do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
    @attempts = [SocketError.new('DNS lookup failed'), nil]
    @client = Bitflyer.realtime_client('key', 'secret')
    @client.child_order_events = ->(_event) {}
    @client.websocket_client.reconnect

    receive_message('0{}')
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('42["subscribe","child_order_events"]').once
  end
end
