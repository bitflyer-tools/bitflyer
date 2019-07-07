require_relative './websocket'

module Bitflyer
  module Realtime
    EVENT_NAMES = %w[lightning_board_snapshot lightning_board lightning_ticker lightning_executions].freeze
    MARKETS = %w[BTC_JPY FX_BTC_JPY ETH_BTC BCH_BTC].freeze
    CHANNEL_NAMES = EVENT_NAMES.product(MARKETS).map { |e, m| e + '_' + m }
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
