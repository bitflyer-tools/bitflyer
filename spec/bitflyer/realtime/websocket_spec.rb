# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::Realtime::WebSocketClient do
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
