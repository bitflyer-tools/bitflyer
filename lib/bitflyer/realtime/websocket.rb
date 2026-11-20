# frozen_string_literal: true

require 'json'
require 'openssl'
require 'bitflyer/realtime/transport'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      CONNECTION_TIMEOUT = 10
      private_constant :CONNECTION_TIMEOUT
      HANDSHAKE_TIMEOUT_MS = 10_000
      private_constant :HANDSHAKE_TIMEOUT_MS

      attr_accessor :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :disconnected, :subscription_failed
      attr_reader :websocket_client, :ready, :last_ping_at, :last_pong_at

      def initialize(host:, key:, secret:, debug: false)
        @host = host
        @key = key
        @secret = secret
        @debug = debug
        @channel_names = []
        @channel_callbacks = {}
        @lifecycle_lock = Mutex.new
        @shutdown_lock = Mutex.new
        @monitor_wakeup = ConditionVariable.new
        @stopped = false
        @authentication_error = nil
        @session_mutex = Thread::Mutex.new
        @subscription_frames = []
        @subscription_writer = Mutex.new
        clear_readiness
        connect
        @monitor = start_monitoring
      end

      def shutdown
        return if @shutdown_lock.owned?

        begin
          @shutdown_lock.synchronize { close_connections }
        ensure
          @monitor&.join unless Thread.current == @monitor
        end
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
        @session_mutex.synchronize do
          @channel_names = (@channel_names + [channel_name]).uniq
          @channel_callbacks[channel_name] = block
          queue_subscription(channel_name) if @session_ready
        end
        send_subscription_frames
      end

      def unsubscribe(channel_name:)
        socket = @session_mutex.synchronize do
          return unless @channel_callbacks.key?(channel_name)

          @channel_callbacks.delete(channel_name)
          @channel_names -= [channel_name]
          @pending_subscriptions.delete_if { |_id, channel| channel == channel_name }
          queue_subscription_frame("42#{['unsubscribe', channel_name].to_json}") if @session_ready
          @websocket_client
        end
        send_subscription_frames
        notify_ready(socket)
      end

      def connect
        close_expired_handshake
        connection = start_connection
        return unless connection

        connected = connection_established?(connection)
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

        debug_log 'Sent ping'
        return if socket&.send('2') == false

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
      rescue OpenSSL::SSL::SSLError => e
        debug_log e
      end

      def handle_error(error:)
        debug_log error
      end

      def handle_message(payload:, socket: @websocket_client) # rubocop:disable Metrics/CyclomaticComplexity
        return if @lifecycle_lock.synchronize { lifecycle_inactive? }

        data = payload.data
        debug_log data
        prefix = /\A\d+/.match(data)
        return unless prefix

        case prefix[0]
        when '0' then setup_by_response(json: prefix.post_match)
        when '3' then receive_pong
        when '41' then disconnect
        when '42' then emit_message(json: prefix.post_match)
        when '430' then authenticated(json: prefix.post_match)
        when /\A43[1-9]\d*\z/
          acknowledge_subscription(id: prefix[0][2..].to_i, json: prefix.post_match, socket: socket)
        end
      rescue JSON::ParserError
        puts 'Invalid JSON in realtime frame'
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

        notify_disconnected(error)
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
        socket = @session_mutex.synchronize do
          return if @awaiting_authentication || @session_ready

          @awaiting_authentication = true
          @websocket_client
        end
        socket&.send "420#{['auth', auth_params].to_json}"
      end

      def authenticated(json:)
        @session_mutex.synchronize do
          return unless @awaiting_authentication

          @awaiting_authentication = false
        end
        return reject_authentication(json) unless authentication_succeeded?(json)

        debug_log 'Authenticated'
        subscribe_channels
      end

      def authentication_succeeded?(json)
        arguments = JSON.parse(json)
        arguments.is_a?(Array) && arguments.first.nil?
      rescue JSON::ParserError
        false
      end

      def subscribe_channels
        socket = @session_mutex.synchronize do
          return if @session_ready

          @session_ready = true
          @channel_callbacks.each_key { |channel| queue_subscription(channel) }
          @last_setup_subscription_id = @next_subscription_id
          @websocket_client
        end
        send_subscription_frames
        notify_ready(socket)
      end

      def acknowledge_subscription(id:, json:, socket: @websocket_client)
        channel, error = @session_mutex.synchronize do
          return unless @websocket_client.equal?(socket)

          channel = @pending_subscriptions[id]
          return unless channel

          error = JSON.parse(json).first
          @pending_subscriptions.delete(id)
          @subscription_rejected = true if error && id <= @last_setup_subscription_id
          [channel, error]
        end
        @subscription_failed&.call(channel, error) if error
        notify_ready(socket)
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

        messages.each do |message|
          break if @lifecycle_lock.synchronize { lifecycle_inactive? }

          callback = @session_mutex.synchronize { @channel_callbacks[channel_name.to_sym] }
          callback&.call(message)
        end
      end

      def debug_log(message)
        return unless @debug

        p message
      end

      private

      def queue_subscription(channel)
        @next_subscription_id += 1
        @pending_subscriptions[@next_subscription_id] = channel
        queue_subscription_frame("42#{@next_subscription_id}#{['subscribe', channel].to_json}")
      end

      def queue_subscription_frame(frame)
        @subscription_frames << [@websocket_client, frame]
      end

      def send_subscription_frames
        return unless @subscription_writer.try_lock

        begin
          # Sending can invoke the close handler, which also takes the session mutex.
          while (entry = take_subscription_frame)
            socket, frame = entry
            debug_log frame
            socket&.send(frame)
          end
        ensure
          @subscription_writer.unlock if @subscription_writer.owned?
        end
      end

      def take_subscription_frame
        @session_mutex.synchronize do
          @subscription_writer.unlock if @subscription_frames.empty?
          @subscription_frames.shift
        end
      end

      def close_expired_handshake
        socket = take_expired_handshake
        return unless socket

        begin
          socket.close_for_shutdown
        ensure
          @lifecycle_lock.synchronize { @expiring_handshake = false }
        end
      end

      def take_expired_handshake
        @lifecycle_lock.synchronize do
          socket = @websocket_client
          deadline = @handshake_deadline
          return unless socket.is_a?(Transport) && deadline && monotonic_milliseconds >= deadline
          return unless pending_handshake?(socket)

          @expiring_handshake = true
          @handshake_deadline = nil
          @session_mutex.synchronize do
            @websocket_client = nil
            clear_readiness
          end
          socket
        end
      end

      def pending_handshake?(socket)
        !lifecycle_inactive? && !@connection && !socket.open? && !socket.closed?
      end

      def close_connections
        socket, connection = stop_lifecycle
        if connection
          transport, connector = connection
          connector.join
          transport.close_for_shutdown unless transport.equal?(socket)
        end
        socket&.close_for_shutdown
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
          return if lifecycle_inactive? || @connection || @expiring_handshake || (socket && !socket.closed?)

          reset_readiness(socket)
          transport = Transport.new
          register_transport_handlers(transport)
          @handshake_deadline = monotonic_milliseconds + HANDSHAKE_TIMEOUT_MS
          connector = Thread.new do
            transport.connect "#{@host}/socket.io/?transport=websocket"
            nil
          rescue StandardError => e
            e
          end
          @connection = [transport, connector]
        end
      end

      def connection_established?(connection)
        connector = connection.last
        unless connector.join(CONNECTION_TIMEOUT)
          debug_log 'Timed out establishing the WebSocket transport'
          return false
        end

        error = connector.value
        raise error if error

        true
      end

      def register_transport_handlers(transport)
        this = self
        activate = -> { activate_transport(transport) }
        transport.on(:open) { activate.call }
        transport.on(:message) do |payload|
          this.handle_message(payload: payload, socket: transport) if this.websocket_client.equal?(transport)
        end
        transport.on(:close) { |error| this.handle_close(error: error, socket: transport) }
      end

      def activate_transport(transport)
        @lifecycle_lock.synchronize do
          return if lifecycle_inactive?
          return unless @connection&.first.equal?(transport) || @websocket_client.equal?(transport)

          replace_transport(transport)
          @handshake_deadline = nil
        end
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
          else
            @handshake_deadline = nil
          end
          !connected
        end
        return unless close_transport

        connector.kill
        connector.join
        transport.close_for_shutdown
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

      def notify_ready(socket)
        notification = @lifecycle_lock.synchronize do
          return if lifecycle_inactive?

          @session_mutex.synchronize do
            return unless @session_ready && @websocket_client.equal?(socket)

            return unless setup_subscriptions_acknowledged?

            @ready_state = :ready if @ready_state == :pending
            take_ready_callback
          end
        end
        notification&.call
      end

      def setup_subscriptions_acknowledged?
        !@subscription_rejected && @pending_subscriptions.keys.none? { |id| id <= @last_setup_subscription_id }
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
        @subscription_frames.clear
        @next_subscription_id = @last_setup_subscription_id = 0
        @pending_subscriptions = {}
        @subscription_rejected = false
        @awaiting_authentication = false
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
          notify_disconnected(error)
        end
      end

      def notify_disconnected(error)
        @disconnected&.call(error)
      rescue StandardError => e
        warn e.full_message(highlight: false)
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
