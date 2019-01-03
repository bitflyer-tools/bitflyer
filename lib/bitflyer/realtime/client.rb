require_relative './websocket'

module Bitflyer
  module Realtime
    CHANNEL_NAMES = [
        'lightning_board_snapshot_BTC_JPY',
        'lightning_board_snapshot_FX_BTC_JPY',
        'lightning_board_snapshot_ETH_BTC',
        'lightning_board_snapshot_BCH_BTC',
        'lightning_board_BTC_JPY',
        'lightning_board_FX_BTC_JPY',
        'lightning_board_ETH_BTC',
        'lightning_board_BCH_BTC',
        'lightning_ticker_BTC_JPY',
        'lightning_ticker_FX_BTC_JPY',
        'lightning_ticker_ETH_BTC',
        'lightning_ticker_BCH_BTC',
        'lightning_executions_BTC_JPY',
        'lightning_executions_FX_BTC_JPY',
        'lightning_executions_ETH_BTC',
        'lightning_executions_BCH_BTC'
    ].freeze

    SOCKET_HOST = 'https://io.lightstream.bitflyer.com'

    class Client
      attr_accessor :websocket_client, :ping_interval, :ping_timeout, :last_ping_at, :last_pong_at

      Realtime::CHANNEL_NAMES.each do |channel_name|
        define_method "#{channel_name.gsub('lightning_', '').downcase.to_sym}=" do |callback|
          @websocket_client.subscribe(channel_name: channel_name.to_sym, &callback)
        end
      end

      def initialize
        @websocket_client = Bitflyer::Realtime::WebSocketClient.new(host: SOCKET_HOST)
      end
    end
  end
end
