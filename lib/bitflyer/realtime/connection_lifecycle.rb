# frozen_string_literal: true

require_relative 'connection_attempt'
require_relative 'transport'

module Bitflyer
  module Realtime
    class ConnectionLifecycle
      RECONNECT_BASE_DELAY = 1.0
      RECONNECT_MAX_DELAY = 30.0
      private_constant :RECONNECT_BASE_DELAY, :RECONNECT_MAX_DELAY

      Events = Struct.new(:reset, :replace, :opened, :message, :closed, :poll, keyword_init: true)

      attr_reader :lock, :transport

      def initialize(host, log, events)
        @host = host
        @log = log
        @events = events
        @lock = Mutex.new
        @shutdown_lock = Mutex.new
        @monitor_wakeup = ConditionVariable.new
        @stopped = @authentication_rejected = false
      end

      def synchronize(&) = @lock.synchronize(&)

      def inactive? = @stopped || @authentication_rejected
      def reset_backoff = @reconnect_delay = RECONNECT_BASE_DELAY

      def reject_authentication
        @authentication_rejected = true
        @monitor_wakeup.signal
      end

      def handle_close(error:, socket: @transport, complete_close: nil)
        @log.call(error)
        synchronize do
          connecting_socket = @connection&.transport
          next if inactive? || !(@events.reset.call(socket) || (socket && connecting_socket.equal?(socket)))

          # Keep retries gated until the previous session has been invalidated.
          complete_close&.call
          @events.closed.call(error)
        end
      end

      def disconnect(socket: @transport)
        @log.call('Disconnecting from server...')
        socket&.close
      end

      def connect
        connection = start_connection
        return unless connection

        connected = connection.established?(@log)
      rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Errno::EHOSTUNREACH, Errno::ENETDOWN, Errno::ENETUNREACH, Errno::EPIPE, Timeout::Error => e
        puts e
        puts e.backtrace&.join("\n")
      ensure
        finish_connection(connection, !!connected) if connection
      end

      def reconnect
        @log.call 'Reconnecting...'
        connect
      rescue StandardError => e
        @log.call e
      end

      def start_monitoring
        @monitor = Thread.new do
          while (tick = wait_for_monitor_tick)
            tick == :retry ? reconnect : @events.poll.call
          end
        end
      end

      def shutdown
        return if @shutdown_lock.owned?

        begin
          @shutdown_lock.synchronize { close_connections }
        ensure
          @monitor&.join unless Thread.current == @monitor
        end
      end

      private

      def start_connection
        synchronize do
          socket = @transport
          return if inactive? || @connection || (socket && !socket.reconnectable?)

          @events.reset.call(socket)
          advance_reconnect_delay
          transport = Transport.new(ssl_context: tls_context)
          register_transport_handlers(transport)
          @connection = ConnectionAttempt.new(transport, "#{@host}/socket.io/?transport=websocket")
        end
      end

      def finish_connection(connection, connected)
        close_transport = synchronize do
          @connection = nil
          return if @stopped

          replace_transport(connection.transport) if connected && !@authentication_rejected
          !connected
        end
        return unless close_transport

        connection.cancel
        connection.close
      end

      def close_connections
        socket, connection = stop_lifecycle
        connection&.close(unless_transport: socket)
        socket&.close_for_shutdown
      end

      def stop_lifecycle
        synchronize do
          next [nil, nil] if @stopped

          @stopped = true
          @events.reset.call(@transport, stopping: true)
          @monitor_wakeup.signal
          @connection&.cancel
          [@transport, @connection]
        end
      end

      def tls_context = @tls_context ||= Transport.default_ssl_context

      def activate_transport(transport)
        synchronize do
          return if inactive?
          return unless @connection&.transport.equal?(transport) || @transport.equal?(transport)

          replace_transport(transport)
          @events.opened.call
        end
      end

      def wait_for_monitor_tick
        synchronize do
          return if inactive?

          socket = @transport
          retrying = !@connection && (!socket || socket.reconnectable?)
          @monitor_wakeup.wait(@lock, retrying ? jittered_reconnect_delay : 1)
          (retrying ? :retry : :poll) unless inactive?
        end
      end

      def advance_reconnect_delay
        delay = @reconnect_delay
        @reconnect_delay = delay ? [delay * 2, RECONNECT_MAX_DELAY].min : RECONNECT_BASE_DELAY
      end

      def jittered_reconnect_delay
        (@reconnect_delay || RECONNECT_BASE_DELAY) * (0.5 + (rand * 0.5))
      end

      def register_transport_handlers(transport)
        transport.on(:open) { activate_transport(transport) }
        transport.on(:message) do |payload|
          @events.message.call(payload, transport) if @transport.equal?(transport)
        end
        transport.on(:close) do |error, complete_close|
          handle_close(error: error, socket: transport, complete_close: complete_close)
        end
      end

      def replace_transport(transport)
        return if @transport.equal?(transport)

        @events.replace.call(transport, -> { @transport = transport })
      end
    end
  end
end
