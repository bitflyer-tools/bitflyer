# frozen_string_literal: true

require 'json'
require 'openssl'
require 'bitflyer/realtime/transport'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      attr_accessor :websocket_client, :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :last_ping_at, :last_pong_at, :ready, :disconnected

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
        connect
        @monitor = start_monitoring
      end

      def shutdown
        socket, connection = @lifecycle_lock.synchronize do
          next [nil, nil] if @stopped

          @stopped = true
          @monitor_wakeup.signal
          @connection&.last&.kill
          [@websocket_client, @connection]
        end

        if connection
          transport, connector = connection
          connector.join
          transport.close
        end
        @monitor.join unless Thread.current == @monitor
      ensure
        socket&.close
      end

      def subscribe(channel_name:, &block)
        debug_log "Subscribe #{channel_name}"
        @channel_names = (@channel_names + [channel_name]).uniq
        @channel_callbacks[channel_name] = block
        @websocket_client.send "42#{['subscribe', channel_name].to_json}"
      end

      def connect
        connection = start_connection
        return unless connection

        error = connection.last.value
        raise error if error

        connected = true
      rescue SocketError => e
        puts e
        puts e.backtrace&.join("\n")
      ensure
        finish_connection(connection, !!connected) if connection
      end

      def send_ping
        last_ping_at = @last_ping_at
        ping_interval = @ping_interval
        return unless last_ping_at && ping_interval
        return unless Time.now.to_i - last_ping_at > ping_interval / 1000

        debug_log 'Sent ping'
        @websocket_client.send '2'
        @last_ping_at = Time.now.to_i
      end

      def wait_pong
        last_pong_at = @last_pong_at
        ping_interval = @ping_interval
        ping_timeout = @ping_timeout
        return unless last_pong_at && ping_interval && ping_timeout
        return unless Time.now.to_i - last_pong_at > (ping_interval + ping_timeout) / 1000

        debug_log 'Timed out waiting pong'
        @websocket_client.close
      end

      def reconnect
        debug_log 'Reconnecting...'
        connect
      end

      def handle_error(error:)
        debug_log error
        return unless error.is_a? Errno::ECONNRESET
        return if @lifecycle_lock.synchronize { @stopped }

        @disconnected&.call(error)
        reconnect
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
        @last_ping_at = Time.now.to_i
        @last_pong_at = Time.now.to_i
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
        @websocket_client.send "420#{['auth', auth_params].to_json}"
      end

      def authenticated(json:)
        raise "Authentication failed: #{json}" if json != '[null]'

        debug_log 'Authenticated'
        subscribe_channels
        @ready&.call
      end

      def subscribe_channels
        @channel_callbacks.each_key do |channel_name|
          debug_log "42#{{ subscribe: channel_name }.to_json}"
          @websocket_client.send "42#{['subscribe', channel_name].to_json}"
        end
      end

      def receive_pong
        debug_log 'Received pong'
        @last_pong_at = Time.now.to_i
      end

      def disconnect
        debug_log 'Disconnecting from server...'
        @websocket_client.close
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

      def start_connection
        @lifecycle_lock.synchronize do
          return if @stopped || @connection || (@websocket_client && !@websocket_client.closed?)

          transport = Transport.new
          connector = Thread.new do
            transport.connect "#{@host}/socket.io/?transport=websocket"
            nil
          rescue StandardError => e
            e
          end
          @connection = [transport, connector]
        end
      end

      def attach_transport(transport)
        @websocket_client = transport
        this = self
        transport.on(:message) { |payload| this.handle_message(payload: payload) }
        transport.on(:error) { |error| this.handle_error(error: error) }
        transport.on(:close) { |error| this.handle_close(error: error) }
        transport.close_on_eof
      end

      def finish_connection(connection, connected)
        transport, connector = connection
        close_transport = @lifecycle_lock.synchronize do
          @connection = nil
          return if @stopped

          attach_transport(transport) if connected
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
    end
  end
end
