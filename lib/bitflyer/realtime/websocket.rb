# frozen_string_literal: true

require 'json'
require 'openssl'
require 'bitflyer/realtime/transport'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      attr_accessor :websocket_client, :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :disconnected
      attr_reader :ready, :last_ping_at, :last_pong_at

      def initialize(host:, key:, secret:, debug: false)
        @host = host
        @key = key
        @secret = secret
        @debug = debug
        @channel_names = []
        @channel_callbacks = {}
        @lifecycle_lock = Mutex.new
        @monitor_wakeup = ConditionVariable.new
        @stopped = false
        @authentication_error = nil
        @session_mutex = Thread::Mutex.new
        @session_ready = false
        @ready_state = :pending
        connect
        @monitor = start_monitoring
      end

      def shutdown
        socket, connection = stop_lifecycle
        if connection
          transport, connector = connection
          connector.join
          transport.close_for_shutdown unless transport.equal?(socket)
        end
        if socket.is_a?(Transport)
          socket.close_for_shutdown
        else
          socket&.close
        end
      ensure
        @monitor&.join unless Thread.current == @monitor
      end

      def inspect = "#<#{self.class}>"

      def ready=(callback)
        notification = @session_mutex.synchronize do
          @ready = callback
          take_ready_callback
        end
        notification&.call
        callback
      end

      def subscribe(channel_name:, &block)
        debug_log "Subscribe #{channel_name}"
        socket = @session_mutex.synchronize do
          @channel_names = (@channel_names + [channel_name]).uniq
          @channel_callbacks[channel_name] = block
          @websocket_client if @session_ready
        end
        socket.send "42#{['subscribe', channel_name].to_json}" if socket&.open?
      end

      def connect
        connection = start_connection
        return unless connection

        connected = wait_for_connection(connection)
      rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
        puts e
        puts e.backtrace&.join("\n")
      ensure
        finish_connection(connection, !!connected) if connection
      end

      def send_ping
        socket = @websocket_client
        last_ping_monotonic = @last_ping_monotonic
        ping_interval = @ping_interval
        return unless last_ping_monotonic && ping_interval

        now = monotonic_milliseconds
        return unless now - last_ping_monotonic >= ping_interval

        return unless write_ping(socket)

        @lifecycle_lock.synchronize do
          if @websocket_client.equal?(socket)
            @last_ping_monotonic = now
            @last_ping_at = Time.now.to_i
          end
        end
      end

      def wait_pong
        socket = @websocket_client
        last_pong_monotonic = @last_pong_monotonic
        ping_interval = @ping_interval
        ping_timeout = @ping_timeout
        return unless last_pong_monotonic && ping_interval && ping_timeout

        now = monotonic_milliseconds
        return unless now - last_pong_monotonic >= ping_interval + ping_timeout

        debug_log 'Timed out waiting pong'
        socket&.close
      end

      def last_ping_at=(timestamp)
        @last_ping_monotonic = monotonic_from_unix_seconds(timestamp)
        @last_ping_at = timestamp
      end

      def last_pong_at=(timestamp)
        @last_pong_monotonic = monotonic_from_unix_seconds(timestamp)
        @last_pong_at = timestamp
      end

      def reconnect
        debug_log 'Reconnecting...'
        connect
      end

      def handle_error(error:, transport: @websocket_client)
        debug_log error
        return unless error.is_a?(Errno::ECONNRESET) || error.is_a?(OpenSSL::SSL::SSLError)
        return unless transport.is_a? Transport
        return unless @lifecycle_lock.synchronize do
          !lifecycle_inactive? && [@websocket_client, @connection&.first].include?(transport)
        end

        transport.close_after_read_error(error)
      end

      def handle_message(payload:) # rubocop:disable Metrics/CyclomaticComplexity
        return if @lifecycle_lock.synchronize { lifecycle_inactive? }

        debug_log payload.data
        return unless payload.data =~ /^\d+/

        code, body = payload.data.scan(/^(\d+)(.*)$/)[0]

        case code.to_i
        when 0 then setup_by_response(json: body)
        when 3 then receive_pong
        when 41 then disconnect
        when 42 then emit_message(json: body)
        when 430 then authenticated(json: body)
        end
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def handle_close(error:, socket: @websocket_client)
        debug_log error
        return unless @lifecycle_lock.synchronize do
          connecting_socket = @connection&.first
          !lifecycle_inactive? && (reset_readiness(socket) || (socket && connecting_socket.equal?(socket)))
        end

        @disconnected&.call(error)
      end

      def setup_by_response(json:)
        body = JSON.parse json
        @ping_interval = body['pingInterval']&.to_i || 25_000
        @ping_timeout  = body['pingTimeout']&.to_i || 60_000
        @last_ping_at = @last_pong_at = Time.now.to_i
        @last_ping_monotonic = @last_pong_monotonic = monotonic_milliseconds
        if @key && @secret
          authenticate
        else
          subscribe_channels
          notify_ready
        end
      end

      def authenticate
        debug_log 'Authenticate'
        timestamp = Time.now.to_i
        nonce = Random.new.bytes(16).unpack1('H*').to_s
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret.to_s, timestamp.to_s + nonce)
        auth_params = {
          api_key: @key,
          timestamp: timestamp,
          nonce: nonce,
          signature: signature
        }
        @websocket_client&.send "420#{['auth', auth_params].to_json}"
      end

      def authenticated(json:)
        return reject_authentication(json) if json != '[null]'

        debug_log 'Authenticated'
        subscribe_channels
        notify_ready
      end

      def subscribe_channels
        socket, channels = @session_mutex.synchronize do
          @session_ready = true
          [@websocket_client, @channel_callbacks.keys]
        end
        channels.each do |channel_name|
          debug_log "42#{{ subscribe: channel_name }.to_json}"
          socket&.send "42#{['subscribe', channel_name].to_json}"
        end
      end

      def receive_pong
        debug_log 'Received pong'
        @last_pong_monotonic = monotonic_milliseconds
        @last_pong_at = Time.now.to_i
      end

      def disconnect
        debug_log 'Disconnecting from server...'
        @websocket_client&.close
      end

      def emit_message(json:)
        channel_name, *messages = JSON.parse json
        return unless channel_name

        messages.each { |message| @channel_callbacks[channel_name.to_sym]&.call(message) }
      end

      def debug_log(message)
        return unless @debug

        p message
      end

      private

      def write_ping(socket)
        debug_log 'Sent ping'
        socket&.send '2'
        true
      rescue IOError, SystemCallError
        raise unless ping_interrupted?(socket)

        false
      rescue NoMethodError => e
        # The transport can clear its socket after the send has started.
        raise unless e.name == :write && e.receiver.nil? && ping_interrupted?(socket)

        false
      end

      def ping_interrupted?(socket)
        return true if socket.is_a?(Transport) && (socket.read_error || socket.closed?)

        @lifecycle_lock.synchronize { lifecycle_inactive? }
      end

      def stop_lifecycle
        @lifecycle_lock.synchronize do
          next [nil, nil] if @stopped

          @stopped = true
          reset_readiness
          @monitor_wakeup.signal
          @connection&.last&.kill
          [@websocket_client, @connection]
        end
      end

      def start_connection
        @lifecycle_lock.synchronize do
          socket = @websocket_client
          return if lifecycle_inactive? || @connection || (socket && !socket.closed?)

          reset_readiness(socket)
          transport = Transport.new
          register_transport_handlers(transport)
          connector = Thread.new do
            transport.connect "#{@host}/socket.io/?transport=websocket"
            nil
          rescue StandardError => e
            e
          end
          @connection = [transport, connector]
        end
      end

      def wait_for_connection(connection)
        error = connection.last.value
        raise error if error

        true
      rescue OpenSSL::SSL::SSLError
        raise unless connection.first.read_error

        false
      end

      def register_transport_handlers(transport)
        this = self
        activate = -> { activate_transport(transport) }
        transport.on(:open) { activate.call }
        transport.on(:message) do |payload|
          this.handle_message(payload: payload) if this.websocket_client.equal?(transport)
        end
        transport.on(:error) { |error| this.handle_error(error: error, transport: transport) }
        transport.on(:close) { |error| this.handle_close(error: error || transport.read_error, socket: transport) }
      end

      def activate_transport(transport)
        @lifecycle_lock.synchronize { replace_transport(transport) unless lifecycle_inactive? }
      end

      def replace_transport(transport)
        return if @websocket_client.equal?(transport)

        @ping_interval = @ping_timeout = nil
        self.last_ping_at = self.last_pong_at = nil
        @session_mutex.synchronize do
          @websocket_client = transport
          clear_readiness
        end
      end

      def finish_connection(connection, connected)
        transport, connector = connection
        close_transport = @lifecycle_lock.synchronize do
          @connection = nil
          return if @stopped

          if connected
            replace_transport(transport) unless @authentication_error
            transport.close_on_eof
          end
          !connected
        end
        return unless close_transport

        connector.kill
        connector.join
        transport.close
      end

      def start_monitoring
        Thread.new do
          while wait_for_monitor_tick
            if @websocket_client&.open?
              send_ping
              wait_pong
            else
              reconnect
            end
          end
        end
      end

      def wait_for_monitor_tick
        @lifecycle_lock.synchronize do
          @monitor_wakeup.wait(@lifecycle_lock, 1) unless lifecycle_inactive?
          !lifecycle_inactive?
        end
      end

      def lifecycle_inactive?
        @stopped || !@authentication_error.nil?
      end

      def notify_ready
        notification = @lifecycle_lock.synchronize do
          return if lifecycle_inactive?

          @session_mutex.synchronize do
            @ready_state = :ready if @ready_state == :pending
            take_ready_callback
          end
        end
        notification&.call
      end

      def take_ready_callback
        return unless @ready_state == :ready && @ready

        @ready_state = :notified
        @ready
      end

      def reset_readiness(socket = @websocket_client)
        @session_mutex.synchronize do
          return false unless @websocket_client.equal?(socket)

          clear_readiness
          true
        end
      end

      def clear_readiness
        @session_ready = false
        @ready_state = :pending
      end

      def reject_authentication(json)
        error = @lifecycle_lock.synchronize do
          return if lifecycle_inactive?

          @authentication_error = RuntimeError.new("Authentication failed: #{json}")
          reset_readiness
          @monitor_wakeup.signal
          @authentication_error
        end

        begin
          disconnect
        rescue SystemCallError, IOError => e
          debug_log e
        ensure
          @disconnected&.call(error)
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
