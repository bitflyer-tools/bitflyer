# frozen_string_literal: true

require 'json'
require 'openssl'
require 'bitflyer/realtime/transport'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      attr_accessor :websocket_client, :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :ready, :disconnected
      attr_reader :last_ping_at, :last_pong_at

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
        @subscriptions_mutex = Thread::Mutex.new
        @session_ready = false
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

      def subscribe(channel_name:, &block)
        debug_log "Subscribe #{channel_name}"
        socket = @subscriptions_mutex.synchronize do
          @channel_names = (@channel_names + [channel_name]).uniq
          @channel_callbacks[channel_name] = block
          @websocket_client if @session_ready
        end
        socket.send "42#{['subscribe', channel_name].to_json}" if socket&.open?
      end

      def connect
        connection = start_connection
        return unless connection

        error = connection.last.value
        raise error if error

        connected = true
      rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
        puts e
        puts e.backtrace&.join("\n")
      ensure
        finish_connection(connection, !!connected) if connection
      end

      def send_ping
        last_ping_monotonic = @last_ping_monotonic
        ping_interval = @ping_interval
        return unless last_ping_monotonic && ping_interval

        now = monotonic_milliseconds
        return unless now - last_ping_monotonic >= ping_interval

        write_ping(now)
      end

      def wait_pong
        last_pong_monotonic = @last_pong_monotonic
        ping_interval = @ping_interval
        ping_timeout = @ping_timeout
        return unless last_pong_monotonic && ping_interval && ping_timeout

        now = monotonic_milliseconds
        return unless now - last_pong_monotonic >= ping_interval + ping_timeout

        debug_log 'Timed out waiting pong'
        @websocket_client&.close
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
        return unless error.is_a? Errno::ECONNRESET
        return unless transport.is_a? Transport
        return if @lifecycle_lock.synchronize { @stopped }

        transport.close_after_reset(error)
      end

      def handle_message(payload:) # rubocop:disable Metrics/CyclomaticComplexity
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

      def handle_close(error:)
        debug_log error
        return if @lifecycle_lock.synchronize { @stopped }

        @disconnected&.call(error)
      end

      def setup_by_response(json:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        body = JSON.parse json
        @ping_interval = body['pingInterval']&.to_i || 25_000
        @ping_timeout  = body['pingTimeout']&.to_i || 60_000
        @last_ping_at = @last_pong_at = Time.now.to_i
        @last_ping_monotonic = @last_pong_monotonic = monotonic_milliseconds
        if @key && @secret
          authenticate
        else
          subscribe_channels
          @ready&.call
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
        raise "Authentication failed: #{json}" if json != '[null]'

        debug_log 'Authenticated'
        subscribe_channels
        @ready&.call
      end

      def subscribe_channels
        socket, channels = @subscriptions_mutex.synchronize do
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

      def write_ping(now)
        debug_log 'Sent ping'
        @websocket_client&.send '2'
        @last_ping_monotonic = now
        @last_ping_at = Time.now.to_i
      rescue IOError, SystemCallError
        raise unless @lifecycle_lock.synchronize { @stopped }
      rescue NoMethodError => e
        # The transport can clear its socket after the send has started.
        raise unless e.name == :write && e.receiver.nil? && @lifecycle_lock.synchronize { @stopped }
      end

      def stop_lifecycle
        @lifecycle_lock.synchronize do
          next [nil, nil] if @stopped

          @stopped = true
          @monitor_wakeup.signal
          @connection&.last&.kill
          [@websocket_client, @connection]
        end
      end

      def start_connection
        @lifecycle_lock.synchronize do
          socket = @websocket_client
          return if @stopped || @connection || (socket && !socket.closed?)

          @subscriptions_mutex.synchronize { @session_ready = false }
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

      def register_transport_handlers(transport)
        this = self
        activate = -> { activate_transport(transport) }
        transport.on(:open) { activate.call }
        transport.on(:message) { |payload| this.handle_message(payload: payload) }
        transport.on(:error) { |error| this.handle_error(error: error, transport: transport) }
        transport.on(:close) { |error| this.handle_close(error: error || transport.reset_error) }
      end

      def activate_transport(transport)
        @lifecycle_lock.synchronize { @websocket_client = transport unless @stopped }
      end

      def finish_connection(connection, connected)
        transport, connector = connection
        close_transport = @lifecycle_lock.synchronize do
          @connection = nil
          return if @stopped

          if connected
            @websocket_client = transport
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
          @monitor_wakeup.wait(@lifecycle_lock, 1) unless @stopped
          !@stopped
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
