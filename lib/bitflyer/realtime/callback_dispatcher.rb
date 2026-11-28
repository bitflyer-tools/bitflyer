# frozen_string_literal: true

require 'json'

module Bitflyer
  module Realtime
    class CallbackDispatcher
      CALLBACK_QUEUE_LIMIT = 1_024
      CALLBACK_PAYLOAD_LIMIT = 8 * 1024 * 1024
      FAILURE_NOTIFICATION_QUEUE_LIMIT = 1_024
      FAILURE_NOTIFICATION_PAYLOAD_LIMIT = 8 * 1024 * 1024
      private_constant :CALLBACK_QUEUE_LIMIT, :CALLBACK_PAYLOAD_LIMIT, :FAILURE_NOTIFICATION_QUEUE_LIMIT,
                       :FAILURE_NOTIFICATION_PAYLOAD_LIMIT

      attr_reader :disconnected

      def initialize(lock, &resolve_callback)
        @lock = lock
        @resolve_callback = resolve_callback
        @callback_queue = []
        @pending_callback_counts = Hash.new(0)
        @callback_wakeup = ConditionVariable.new
        clear_callback_queue
      end

      # Session transitions and channel cancellation call these with the lifecycle lock held.
      def reset(socket = nil)
        @callback_transport = socket
        clear_callback_queue
      end

      def stop
        @stopped = true
        reset
        @callback_wakeup.signal
      end

      def enqueue_callback(channel, token, message, socket)
        return if @pending_callback_counts[:market_data] >= CALLBACK_QUEUE_LIMIT

        bytes = JSON.generate(message, allow_nan: true).bytesize
        @lock.synchronize do
          return unless active_callback_transport?(socket)
          return if @pending_callback_counts[:market_data] >= CALLBACK_QUEUE_LIMIT
          return if @pending_callback_bytes + bytes > CALLBACK_PAYLOAD_LIMIT
          return unless @resolve_callback.call(channel, token, socket)

          push_callback(:market_data, [bytes, channel, token, message, socket])
        end
      end

      def enqueue_notification(socket, kind, bytes: 0, &notification)
        @lock.synchronize do
          return unless active_callback_transport?(socket)

          if kind == :subscription_failed
            return if @pending_callback_counts[kind] >= FAILURE_NOTIFICATION_QUEUE_LIMIT
            return if @pending_failure_bytes + bytes > FAILURE_NOTIFICATION_PAYLOAD_LIMIT
          end

          push_callback(kind, [bytes, nil, nil, notification, socket])
        end
      end

      def discard_channel_callbacks(channel_name)
        @callback_queue.delete_if do |kind, event|
          next false unless kind == :market_data && event[1] == channel_name

          @pending_callback_counts[kind] -= 1
          adjust_payload_bytes(kind, -event.first)
          true
        end
      end

      def disconnected=(callback)
        error = @lock.synchronize do
          @disconnected = callback
          next unless callback

          pending_error = @pending_authentication_error
          @pending_authentication_error = nil
          pending_error
        end
        notify_disconnected(error, callback) if error && callback
        callback
      end

      def notify_authentication_failure(error)
        @lock.synchronize do
          @pending_authentication_error = error unless @disconnected
          dispatch_disconnected(error, @disconnected)
        end
      end

      def dispatch_disconnected(error, callback = @disconnected)
        return unless callback

        if @disconnect_worker&.alive?
          @pending_disconnect = [error, callback]
        else
          @pending_disconnect = nil
          @disconnect_worker = Thread.new { deliver_disconnects([error, callback]) }
        end
      end

      private

      def push_callback(kind, event)
        @callback_worker ||= Thread.new { deliver_callbacks }
        @callback_queue << [kind, event]
        @pending_callback_counts[kind] += 1
        adjust_payload_bytes(kind, event.first)
        @callback_wakeup.signal
      end

      def adjust_payload_bytes(kind, delta)
        return @pending_failure_bytes += delta if kind == :subscription_failed

        @pending_callback_bytes += delta
      end

      def deliver_callbacks
        while (event = next_callback_event)
          _bytes, channel, token, message, socket = event
          deliver_callback(channel, token, message, socket)
        end
      end

      def next_callback_event
        @lock.synchronize do
          @callback_wakeup.wait(@lock) while @callback_queue.empty? && !@stopped
          entry = @callback_queue.shift
          next unless entry

          kind, event = entry
          @pending_callback_counts[kind] -= 1
          adjust_payload_bytes(kind, -event.first)
          event
        end
      end

      def deliver_callback(channel, token, message, socket)
        callback = @lock.synchronize do
          return unless active_callback_transport?(socket)

          @resolve_callback.call(channel, token, socket) if channel
        end
        channel ? callback&.call(message) : message.call
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def active_callback_transport?(socket)
        !@stopped && socket && @callback_transport.equal?(socket) && !socket.closed?
      end

      def clear_callback_queue
        @callback_queue.clear
        @pending_callback_counts.clear
        @pending_callback_bytes = 0
        @pending_failure_bytes = 0
      end

      def deliver_disconnects(notification)
        while notification
          notify_disconnected(*notification)
          notification = next_disconnect_notification
        end
      end

      def next_disconnect_notification
        @lock.synchronize do
          pending = @pending_disconnect
          @pending_disconnect = nil
          @disconnect_worker = nil unless pending
          pending
        end
      end

      def notify_disconnected(error, callback)
        callback.call(error)
      rescue StandardError => e
        warn e.full_message(highlight: false)
      end
    end
  end
end
