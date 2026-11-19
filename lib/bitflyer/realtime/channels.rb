# frozen_string_literal: true

module Bitflyer
  module Realtime
    def self.channel_setter_name(channel_name)
      "#{channel_name.gsub('lightning_', '').downcase}="
    end

    PUBLIC_EVENT_NAMES = %w[lightning_board_snapshot lightning_board lightning_ticker lightning_executions].freeze
    MARKETS = %w[BTC_JPY XRP_JPY ETH_JPY XLM_JPY MONA_JPY ETH_BTC BCH_BTC FX_BTC_JPY BTCJPY_MAT1WK BTCJPY_MAT2WK
                 BTCJPY_MAT3M].freeze
    PUBLIC_CHANNEL_NAMES = PUBLIC_EVENT_NAMES.product(MARKETS).map { |e, m| "#{e}_#{m}" }.freeze
    PRIVATE_CHANNEL_NAMES = %w[child_order_events parent_order_events].freeze
    CHANNEL_NAMES = (PUBLIC_CHANNEL_NAMES + PRIVATE_CHANNEL_NAMES).freeze
  end
end
