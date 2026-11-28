# frozen_string_literal: true

require 'forwardable'
require_relative 'callback_dispatcher'
require_relative 'connection_lifecycle'
require_relative 'heartbeat'
require_relative 'order_book_feeds'
require_relative 'socket_io_session'
require_relative 'subscription_registry'
require_relative 'subscription_session'

module Bitflyer
  module Realtime
    class WebSocketClient
      extend Forwardable

      def_delegators :@connection, :connect, :reconnect, :shutdown, :handle_close, :disconnect
      def_delegator :@connection, :transport, :websocket_client
      def_delegators :@protocol, :handle_message, :setup_by_response, :authenticate, :authenticated,
                     :authentication_succeeded?, :emit_message
      def_delegators :@heartbeat, :send_ping, :wait_pong, :receive_pong, :ping_interval, :ping_interval=,
                     :ping_timeout, :ping_timeout=, :last_ping_at, :last_ping_at=, :last_pong_at, :last_pong_at=
      def_delegators :@subscriptions, :subscribe, :unsubscribe, :order_book, :channel_names, :channel_callbacks,
                     :ready, :ready=, :subscription_failed, :subscription_failed=,
                     :subscribe_channels, :acknowledge_subscription
      def_delegators :@dispatcher, :disconnected, :disconnected=

      def initialize(host:, key:, secret:, debug: false)
        @debug = debug
        log = ->(message) { debug_log(message) }
        @connection = ConnectionLifecycle.new(host, log, connection_events)
        @heartbeat = Heartbeat.new(@connection, log)
        registry = SubscriptionRegistry.new(log)
        @dispatcher = CallbackDispatcher.new(@connection.lock) do |channel, token, socket|
          @subscriptions.subscribed_callback(channel, token, socket)
        end
        @subscriptions = SubscriptionSession.new(@connection, registry, OrderBookFeeds.new, @dispatcher, log)
        @protocol = SocketIOSession.new(@connection, @heartbeat, @subscriptions, @dispatcher, [key, secret], log)
        connect
        @connection.start_monitoring
      end

      def inspect = "#<#{self.class}>"

      def handle_error(error:)
        debug_log error
      end

      def debug_log(message)
        p message if @debug
      end

      private

      # Always acquire the lifecycle lock before the subscription session lock.
      # Transport writes, closes, and user callbacks run outside those locks.
      def connection_events
        ConnectionLifecycle::Events.new(
          reset: ->(socket, stopping: false) { reset_session(socket, stopping: stopping) },
          replace: ->(socket, publish) { replace_transport(socket, publish) },
          opened: -> { @protocol.opened },
          message: ->(payload, socket) { handle_message(payload: payload, socket: socket) },
          closed: ->(error) { @dispatcher.dispatch_disconnected(error) }, poll: -> { poll_transport }
        )
      end

      def reset_session(socket, stopping: false)
        @dispatcher.stop if stopping
        @subscriptions.reset_for(socket) do
          @heartbeat.clear_pending
          @protocol.reset
        end
      end

      def replace_transport(socket, publish)
        @heartbeat.reset
        @protocol.replace
        @subscriptions.reset_for(socket, replacement: true, &publish)
      end

      def poll_transport
        socket = websocket_client
        return unless socket&.open?
        return if @protocol.session_expired?(socket)

        send_ping
        wait_pong
        @subscriptions.expire(socket)
      end
    end
  end
end
