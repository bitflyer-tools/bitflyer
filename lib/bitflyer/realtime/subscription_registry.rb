# frozen_string_literal: true

require 'json'

module Bitflyer
  module Realtime
    class SubscriptionRegistry
      ACK_TIMEOUT_MS = 10_000
      private_constant :ACK_TIMEOUT_MS

      attr_reader :lock

      def initialize(log)
        @lock = Mutex.new
        @subscription_writer = Mutex.new
        @log = log
        @channel_callbacks = {}
        @subscription_tokens = {}
        reset
      end

      # The session lock covers registry updates and changes to the associated transport.
      def reset
        @subscription_frames = []
        @next_subscription_id = @last_setup_subscription_id = 0
        @pending_setup_subscription_count = 0
        @pending_subscriptions = {}
        @pending_subscription_ids = {}
        @acknowledged_subscriptions = {}
        @subscription_ack_deadline = nil
        @subscription_rejected = false
      end

      def channels = @channel_callbacks.keys
      def callbacks = @channel_callbacks.dup.freeze

      def register(channel, callback)
        @subscription_tokens[channel] ||= Object.new
        @channel_callbacks[channel] = callback
      end

      def unregister?(channel)
        return false unless @channel_callbacks.key?(channel)

        @channel_callbacks.delete(channel)
        @subscription_tokens.delete(channel)
        true
      end

      def acknowledged?(channel) = @acknowledged_subscriptions.key?(channel)

      def token(channel)
        @subscription_tokens[channel] if @channel_callbacks[channel]
      end

      def callback(channel, token)
        @channel_callbacks[channel] if @subscription_tokens[channel].equal?(token)
      end

      def setup(channels, socket)
        channels.each { |channel| queue_subscription(channel, socket) }
        @last_setup_subscription_id = @next_subscription_id
        @pending_setup_subscription_count = @pending_subscriptions.size
        @subscription_ack_deadline = monotonic_milliseconds + ACK_TIMEOUT_MS if setup_subscriptions_pending?
      end

      def acknowledge(id, json)
        pending = @pending_subscriptions[id]
        return unless pending && pending.last != :queued
        return :expired if expire_setup_subscriptions

        arguments = JSON.parse(json)
        return unless arguments.is_a?(Array)

        channel = pending.first
        error = arguments.first
        remove_pending_subscription(channel)
        record_subscription_result(id, channel, error)
        [channel, error]
      end

      def expire_runtime_subscriptions
        now = monotonic_milliseconds
        expired = @pending_subscriptions.values.filter_map do |channel, deadline|
          channel if deadline.is_a?(Integer) && now >= deadline
        end
        expired.each { |channel| remove_pending_subscription(channel) }
        expired
      end

      def queue_subscription(channel, socket)
        return if @acknowledged_subscriptions.key?(channel)
        return if @pending_subscription_ids.key?(channel)

        id = @next_subscription_id += 1
        @pending_subscriptions[id] = [channel, :queued]
        @pending_subscription_ids[channel] = id
        @subscription_frames << [socket, "42#{id}#{['subscribe', channel].to_json}", id]
      end

      def cancel_subscription(channel, socket, session_ready)
        id = @pending_subscription_ids[channel]
        undispatched = id && @pending_subscriptions[id]&.last == :queued
        remove_pending_subscription(channel)
        @acknowledged_subscriptions.delete(channel)
        if undispatched
          @subscription_frames.reject! { |entry| entry.last == id }
        elsif session_ready
          @subscription_frames << [socket, "42#{['unsubscribe', channel].to_json}", nil]
        end
      end

      def flush
        return unless @subscription_writer.try_lock

        begin
          # Sending can invoke the close handler, which also takes the session mutex.
          while (entry = take_subscription_frame)
            socket, frame = entry
            @log.call(frame)
            socket&.send(frame)
          end
        ensure
          @subscription_writer.unlock if @subscription_writer.owned?
        end
      end

      def expire_setup_subscriptions
        deadline = @subscription_ack_deadline
        return unless deadline && monotonic_milliseconds >= deadline && setup_subscriptions_pending?

        @subscription_ack_deadline = nil
        @subscription_rejected = true
        @pending_setup_subscription_count = 0
        @pending_subscriptions.clear
        @pending_subscription_ids.clear
        true
      end

      def setup_acknowledged?
        !@subscription_rejected && !setup_subscriptions_pending?
      end

      private

      def take_subscription_frame
        @lock.synchronize do
          while (entry = @subscription_frames.shift)
            socket, frame, id = entry
            return [socket, frame] if !id || begin_subscription_dispatch?(id)
          end
          @subscription_writer.unlock
          nil
        end
      end

      def begin_subscription_dispatch?(id)
        pending = @pending_subscriptions[id]
        return false unless pending && pending.last == :queued

        deadline = monotonic_milliseconds + ACK_TIMEOUT_MS if id > @last_setup_subscription_id
        pending[1] = deadline
        true
      end

      def record_subscription_result(id, channel, error)
        if error.nil?
          @acknowledged_subscriptions[channel] = true
        elsif id <= @last_setup_subscription_id
          @subscription_rejected = true
        end
      end

      def remove_pending_subscription(channel)
        id = @pending_subscription_ids.delete(channel)
        return unless id

        @pending_subscriptions.delete(id)
        @pending_setup_subscription_count -= 1 if id <= @last_setup_subscription_id
      end

      def setup_subscriptions_pending? = @pending_setup_subscription_count.positive?

      def monotonic_milliseconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end
