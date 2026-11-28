# frozen_string_literal: true

require 'json'

module Bitflyer
  module Realtime
    class SubscriptionNotifications
      attr_reader :ready
      attr_accessor :subscription_failed

      def initialize(dispatcher)
        @dispatcher = dispatcher
        reset
      end

      def reset = @state = :pending

      def register_ready(callback, socket)
        @ready = callback
        take_ready(socket)
      end

      def mark_ready(socket)
        if @state == :pending
          yield
          @state = :ready
        end
        take_ready(socket)
      end

      def enqueue_ready(socket, callback)
        @dispatcher.enqueue_notification(socket, :ready) { callback.call } if callback
      end

      def failure(socket, channel, error)
        callback = @subscription_failed
        return if error.nil? || !callback

        bytes = JSON.generate(error, allow_nan: true).bytesize
        @dispatcher.enqueue_notification(socket, :subscription_failed, bytes: bytes) { callback.call(channel, error) }
      end

      private

      def take_ready(socket)
        return unless @state == :ready && @ready
        return if socket&.closed?

        @state = :notified
        @ready
      end
    end
  end
end
