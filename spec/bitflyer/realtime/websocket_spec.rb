# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

describe Bitflyer::Realtime::WebSocketClient do
  let(:socket) { instance_double(WebSocket::Client::Simple::Client, open?: true, send: nil) }
  let(:ticks) { Queue.new }
  let(:waiting) { Queue.new }
  let(:handlers) { {} }

  before do
    tick_queue = ticks
    waiting_queue = waiting
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(WebSocket::Client::Simple).to receive(:connect) do
      attempt = @attempts.shift
      raise attempt if attempt.is_a?(Exception)

      attempt
    end
    allow_any_instance_of(described_class).to receive(:sleep) do
      waiting_queue.push(Thread.current)
      tick_queue.pop
    end
    allow($stdout).to receive(:puts)
  end

  after do
    @monitor&.kill
    @monitor&.join
  end

  def wait_for_monitor
    @monitor = Timeout.timeout(5) { waiting.pop }
  end

  def tick_monitor
    ticks.push(true)
    wait_for_monitor
  end

  def receive_message(data)
    handlers.fetch(:message).call(double('WebSocket payload', data: data))
  end

  it 'replays subscriptions registered during the initial outage once the session is ready' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    events = []
    client.ticker_btc_jpy = ->(event) { events << event }
    tick_monitor
    client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('42["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    tick_monitor
    expect(@monitor).to be_alive
    expect(client.websocket_client.websocket_client).to be_nil

    tick_monitor
    expect(client.websocket_client.websocket_client).to eq(socket)
  end

  it 'waits for authentication before replaying private subscriptions' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client('key', 'secret')
    wait_for_monitor
    client.child_order_events = ->(_event) {}
    tick_monitor

    receive_message('0{}')
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('42["subscribe","child_order_events"]').once
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'debug logging' do
  subject(:client) { described_class.new(host: 'wss://example.test', key: 'key', secret: 'secret', debug: true) }

  let(:socket) { double('websocket', on: nil, send: nil) }

  before do
    allow(WebSocket::Client::Simple).to receive(:connect).and_return(socket)
    allow_any_instance_of(described_class).to receive(:start_monitoring)
  end

  %w[child_order_events parent_order_events].each do |channel_name|
    it "logs only packet metadata and delivers the original #{channel_name} event" do
      event = [{ "#{channel_name.delete_suffix('_events')}_id" => 'dummy-private-order', 'size' => 0.1 }]
      payload = double('frame', data: "42#{[channel_name, event].to_json}")
      received = []
      expected_log = [
        "Subscribe #{channel_name}",
        'Received packet 42',
        "Received event on #{channel_name}"
      ].map(&:inspect).join("\n") + "\n"

      expect do
        client.subscribe(channel_name: channel_name.to_sym) { |message| received << message }
        client.handle_message(payload: payload)
      end.to output(expected_log).to_stdout
      expect(received).to eq([event])
    end
  end
end
