# frozen_string_literal: true

module Bitflyer
  module Realtime
    class Heartbeat
      PingWrite = Struct.new(:acknowledged)
      private_constant :PingWrite

      attr_accessor :ping_interval, :ping_timeout, :last_pong_at
      attr_reader :last_ping_at

      def initialize(connection, log)
        @connection = connection
        @log = log
      end

      def reset
        clear_pending
        @ping_interval = @ping_timeout = nil
        self.last_ping_at = self.last_pong_at = nil
      end

      def clear_pending
        @ping_write = @pong_deadline = nil
      end

      def send_ping
        socket = @connection.transport
        return unless socket

        ping = begin_ping(socket)
        return unless ping

        sent = socket.send('2')
        sent_at = monotonic_milliseconds if sent
        @log.call 'Sent ping' if sent
      ensure
        finish_ping(ping, sent_at) if ping
      end

      def wait_pong
        socket = @connection.synchronize do
          deadline = @pong_deadline
          @connection.transport if deadline && monotonic_milliseconds >= deadline
        end
        return unless socket

        @log.call 'Timed out waiting pong'
        socket.close
      end

      def last_ping_at=(timestamp)
        @last_ping_monotonic = monotonic_from_unix_seconds(timestamp)
        @last_ping_at = timestamp
      end

      def receive_pong(socket: @connection.transport)
        @connection.synchronize do
          return if @connection.inactive? || !socket || !@connection.transport.equal?(socket)

          ping = @ping_write
          ping.acknowledged = true if ping
          @pong_deadline = nil
          @last_pong_at = Time.now.to_i
        end
        @log.call 'Received pong'
      end

      def setup(body)
        @ping_interval = body['pingInterval']&.to_i || 25_000
        @ping_timeout = body['pingTimeout']&.to_i || 60_000
        @last_ping_at = @last_pong_at = Time.now.to_i
        @ping_write = @pong_deadline = nil
        @last_ping_monotonic = monotonic_milliseconds
      end

      private

      def begin_ping(socket)
        @connection.synchronize do
          return unless @connection.transport.equal?(socket) && !@connection.inactive?
          return if @ping_write || @pong_deadline
          return unless ping_due?

          @ping_write = PingWrite.new(false)
        end
      end

      def ping_due?
        last_ping = @last_ping_monotonic
        interval = @ping_interval
        last_ping && interval && monotonic_milliseconds - last_ping >= interval
      end

      def finish_ping(ping, sent_at)
        @connection.synchronize do
          return unless @ping_write.equal?(ping)

          @ping_write = nil
          return unless sent_at

          @last_ping_monotonic = sent_at
          @last_ping_at = Time.now.to_i
          timeout = @ping_timeout
          @pong_deadline = sent_at + timeout if timeout && !ping.acknowledged
        end
      end

      def monotonic_milliseconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end

      def monotonic_from_unix_seconds(timestamp)
        return if timestamp.nil?

        elapsed_milliseconds = (Time.now.to_i - timestamp) * 1000
        monotonic_milliseconds - elapsed_milliseconds
      end
    end
  end
end
