# frozen_string_literal: true

require 'forwardable'
require_relative 'channels'
require_relative 'websocket'

module Bitflyer
  module Realtime
    SOCKET_HOST = 'https://io.lightstream.bitflyer.com'

    class Client
      extend Forwardable

      def_delegators :@websocket_client, :ready=, :disconnected=, :shutdown
      def_delegators :@websocket_client, :ping_interval, :ping_interval=, :ping_timeout, :ping_timeout=,
                     :last_ping_at, :last_ping_at=, :last_pong_at, :last_pong_at=
      attr_accessor :websocket_client

      Realtime::CHANNEL_NAMES.each do |channel_name|
        define_method Realtime.channel_setter_name(channel_name) do |callback|
          @websocket_client.subscribe(channel_name: channel_name.to_sym, &callback)
          callback
        end
      end

      def initialize(key = nil, secret = nil)
        @websocket_client = Bitflyer::Realtime::WebSocketClient.new(host: SOCKET_HOST, key: key, secret: secret)
      end

      def inspect = "#<#{self.class}>"
    end
  end
end
