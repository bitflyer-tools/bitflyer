# frozen_string_literal: true

require 'forwardable'
require_relative 'websocket'

module Bitflyer
  module Realtime
    PUBLIC_EVENT_NAMES = %w[lightning_board_snapshot lightning_board lightning_ticker lightning_executions].freeze
    MARKETS = %w[BTC_JPY XRP_JPY ETH_JPY XLM_JPY MONA_JPY ETH_BTC BCH_BTC FX_BTC_JPY BTCJPY_MAT1WK BTCJPY_MAT2WK
                 BTCJPY_MAT3M].freeze
    PUBLIC_CHANNEL_NAMES = PUBLIC_EVENT_NAMES.product(MARKETS).map { |e, m| "#{e}_#{m}" }.freeze
    PRIVATE_CHANNEL_NAMES = %w[child_order_events parent_order_events].freeze
    CHANNEL_NAMES = (PUBLIC_CHANNEL_NAMES + PRIVATE_CHANNEL_NAMES).freeze

    SOCKET_HOST = 'https://io.lightstream.bitflyer.com'

    class Client
      extend Forwardable

      def_delegators :@websocket_client, :ready=, :disconnected=
      attr_accessor :websocket_client, :ping_interval, :ping_timeout, :last_ping_at, :last_pong_at

      Realtime::CHANNEL_NAMES.each do |channel_name|
        define_method "#{channel_name.gsub('lightning_', '').downcase.to_sym}=" do |callback|
          @websocket_client.subscribe(channel_name: channel_name.to_sym, &callback)
        end
      end

      def initialize(key = nil, secret = nil)
        @websocket_client = Bitflyer::Realtime::WebSocketClient.new(host: SOCKET_HOST, key: key, secret: secret)
      end
    end
  end
end
