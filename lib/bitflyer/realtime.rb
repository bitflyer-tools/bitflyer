require 'pubnub'

module Bitflyer
  class Realtime
    PUBNUB_SUBSCRIBE_KEY = 'sub-c-52a9ab50-291b-11e5-baaa-0619f8945a4f'.freeze
    CHANNEL_NAMES = [
        'lightning_board_snapshot_BTC_JPY',
        'lightning_board_snapshot_FX_BTC_JPY',
        'lightning_board_snapshot_ETH_BTC',
        'lightning_board_BTC_JPY',
        'lightning_board_FX_BTC_JPY',
        'lightning_board_ETH_BTC',
        'lightning_ticker_BTC_JPY',
        'lightning_ticker_FX_BTC_JPY',
        'lightning_ticker_ETH_BTC',
        'lightning_executions_BTC_JPY',
        'lightning_executions_FX_BTC_JPY',
        'lightning_executions_ETH_BTC'
    ].freeze

    attr_accessor *CHANNEL_NAMES.map { |name| name.gsub('lightning_', '').downcase.to_sym }

    def initialize
      @pubnub = Pubnub.new(subscribe_key: PUBNUB_SUBSCRIBE_KEY)

      @callback = Pubnub::SubscribeCallback.new(
          message: ->(envelope) {
            channel_name = envelope.result[:data][:subscribed_channel].gsub('lightning_', '').downcase.to_sym
            message = envelope.result[:data][:message]
            send(channel_name).call(message) if send(channel_name)
          },
          presence: ->(envelope) {},
          status: ->(envelope) {}
      )

      @pubnub.add_listener(callback: @callback)
      @pubnub.subscribe(channels: CHANNEL_NAMES)
    end
  end
end