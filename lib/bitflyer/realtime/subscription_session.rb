# frozen_string_literal: true

require 'forwardable'
require_relative 'channels'
require_relative 'subscription_notifications'

module Bitflyer
  module Realtime
    class SubscriptionSession
      def initialize(connection, registry, feeds, dispatcher, log)
        @connection = connection
        @registry = registry
        @feeds = feeds
        @dispatcher = dispatcher
        @log = log
        @notifications = SubscriptionNotifications.new(dispatcher)
        reset
      end

      extend Forwardable

      def_delegators :@notifications, :ready, :subscription_failed, :subscription_failed=

      def before_start
        @registry.lock.synchronize { yield unless @session_ready }
      end

      def channel_names = @registry.lock.synchronize { registered_channels.freeze }

      def channel_callbacks = @registry.lock.synchronize { @registry.callbacks }

      def subscribe(channel_name:, &block)
        @log.call("Subscribe #{channel_name}")
        @registry.lock.synchronize do
          @registry.register(channel_name, block)
          @registry.queue_subscription(channel_name, @connection.transport) if @session_ready
        end
        @registry.flush
      end

      def order_book(product_code:)
        book = @registry.lock.synchronize do
          book, delta, snapshot = @feeds.register(product_code)
          if @session_ready
            @registry.queue_subscription(delta, @connection.transport)
            @registry.queue_subscription(snapshot, @connection.transport)
          end
          book
        end
        @registry.flush
        book
      end

      def unsubscribe(channel_name:)
        socket = @connection.synchronize do
          @registry.lock.synchronize do
            return unless @registry.unregister?(channel_name)

            @dispatcher.discard_channel_callbacks(channel_name)
            return if @feeds.include?(channel_name)

            transport = @connection.transport
            @registry.cancel_subscription(channel_name, transport, @session_ready)
            transport
          end
        end
        @registry.flush
        notify_ready(socket)
      end

      def subscribe_channels(socket: @connection.transport, authenticated: false)
        @registry.lock.synchronize do
          return if !@connection.transport.equal?(socket) || @session_ready

          @session_authenticated = authenticated
          @session_ready = true
          @registry.setup(registered_channels, socket)
        end
        @registry.flush
        notify_ready(socket)
      end

      def acknowledge_subscription(id:, json:, socket: @connection.transport)
        result = @registry.lock.synchronize do
          return unless @connection.transport.equal?(socket)

          @registry.acknowledge(id, json)
        end
        return unless result
        return close_subscription_timeout(socket) unless result.is_a?(Array)

        channel, error = result
        @notifications.failure(socket, channel, error)
        notify_ready(socket)
      end

      def expire(socket)
        expired_socket = @registry.lock.synchronize { @connection.transport if @registry.expire_setup_subscriptions }
        close_subscription_timeout(expired_socket) if expired_socket
        expire_runtime_subscriptions(socket)
      end

      def subscribed_callback(channel, token, socket)
        @registry.lock.synchronize do
          return unless @connection.transport.equal?(socket) && callback_channel_ready?(channel)

          @registry.callback(channel, token)
        end
      end

      def deliver(channel, messages, socket)
        token = message_token(channel, messages, socket)
        return unless token

        messages.each { |message| @dispatcher.enqueue_callback(channel, token, message, socket) }
      end

      # Transport publication and session reset are one transaction.
      def reset_for(socket, replacement: false)
        @registry.lock.synchronize do
          return false unless replacement || @connection.transport.equal?(socket)

          yield
          @dispatcher.reset(replacement ? socket : nil)
          reset
          true
        end
      end

      def ready=(callback)
        notification = @registry.lock.synchronize { @notifications.register_ready(callback, @connection.transport) }
        notification&.call
        callback
      end

      private

      def reset
        @feeds.invalidate
        @registry.reset
        @session_authenticated = false
        @session_ready = false
        @notifications.reset
      end

      def expire_runtime_subscriptions(socket)
        expired = @registry.lock.synchronize do
          return unless @connection.transport.equal?(socket) && socket.open?

          @registry.expire_runtime_subscriptions
        end
        expired.each do |channel|
          @notifications.failure(socket, channel, 'Timed out waiting for subscription acknowledgment')
        end
      end

      def registered_channels = @feeds.channels | @registry.channels

      def message_token(channel, messages, socket)
        @registry.lock.synchronize do
          return unless @connection.transport.equal?(socket)

          @feeds.route(channel, messages) { |delta| @registry.acknowledged?(delta) }
          return unless callback_channel_ready?(channel)

          @registry.token(channel)
        end
      end

      def callback_channel_ready?(channel)
        !PRIVATE_CHANNEL_NAMES.include?(channel.to_s) ||
          (@session_authenticated && @registry.acknowledged?(channel))
      end

      def notify_ready(socket)
        notification = @connection.synchronize do
          return if @connection.inactive?

          @registry.lock.synchronize do
            return unless @session_ready && @connection.transport.equal?(socket)

            return unless @registry.setup_acknowledged?

            @notifications.mark_ready(socket) { @connection.reset_backoff }
          end
        end
        @notifications.enqueue_ready(socket, notification)
      end

      def close_subscription_timeout(socket)
        @log.call 'Timed out waiting for setup subscription acknowledgments'
        socket&.close
      end
    end
  end
end
