# frozen_string_literal: true

require 'websocket-client-simple'
require 'json'
require 'openssl'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      attr_accessor :websocket_client, :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :last_ping_at, :last_pong_at, :ready, :disconnected, :subscription_failed

      def initialize(host:, key:, secret:, debug: false)
        @host = host
        @key = key
        @secret = secret
        @debug = debug
        @channel_names = []
        @channel_callbacks = {}
        @pending_subscriptions = {}
        @subscription_rejected = false
        @awaiting_authentication = false
        @subscriptions_mutex = Thread::Mutex.new
        @session_ready = false
        connect
        start_monitoring
      end

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
        @websocket_client = nil
        reset_session
        socket = WebSocket::Client::Simple.connect "#{@host}/socket.io/?transport=websocket"
        @websocket_client = socket
        this = self
        socket.on(:message) { |payload| this.handle_message(payload: payload) if this.websocket_client.equal?(socket) }
        socket.on(:error) { |error| this.handle_error(error: error) if this.websocket_client.equal?(socket) }
        socket.on(:close) { |error| this.handle_close(error: error) if this.websocket_client.equal?(socket) }
      rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def start_monitoring
        Thread.new do
          loop do
            sleep 1
            if @websocket_client&.open?
              send_ping
              wait_pong
            else
              reconnect
            end
          end
        end
      end

      def send_ping
        last_ping_at = @last_ping_at
        ping_interval = @ping_interval
        return unless last_ping_at && ping_interval
        return unless Time.now.to_i - last_ping_at > ping_interval / 1000

        debug_log 'Sent ping'
        @websocket_client&.send '2'
        @last_ping_at = Time.now.to_i
      end

      def wait_pong
        last_pong_at = @last_pong_at
        ping_interval = @ping_interval
        ping_timeout = @ping_timeout
        return unless last_pong_at && ping_interval && ping_timeout
        return unless Time.now.to_i - last_pong_at > (ping_interval + ping_timeout) / 1000

        debug_log 'Timed out waiting pong'
        @websocket_client&.close
      end

      def reconnect
        return if @websocket_client&.open?

        debug_log 'Reconnecting...'

        connect
      end

      def handle_error(error:)
        debug_log error
        return unless error.is_a? Errno::ECONNRESET

        @disconnected&.call(error)
        reconnect
      end

      def handle_message(payload:) # rubocop:disable Metrics/CyclomaticComplexity
        debug_log payload.data
        return unless payload.data =~ /^\d+/

        code, body = payload.data.scan(/^(\d+)(.*)$/)[0]

        case code
        when '0' then setup_by_response(json: body)
        when '3' then receive_pong
        when '41' then disconnect
        when '42' then emit_message(json: body)
        when '430' then authenticated(json: body)
        when /\A43[1-9]\d*\z/ then acknowledge_subscription(id: code[2..].to_i, json: body)
        end
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def handle_close(error:)
        debug_log error
        reset_session
        @disconnected&.call(error)
      end

      def setup_by_response(json:)
        body = JSON.parse json
        @ping_interval = body['pingInterval']&.to_i || 25_000
        @ping_timeout  = body['pingTimeout']&.to_i || 60_000
        @last_ping_at = Time.now.to_i
        @last_pong_at = Time.now.to_i
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
        @awaiting_authentication = true
        @websocket_client&.send "420#{['auth', auth_params].to_json}"
      end

      def authenticated(json:)
        return unless @awaiting_authentication

        @awaiting_authentication = false
        raise "Authentication failed: #{json}" if json != '[null]'

        debug_log 'Authenticated'
        subscribe_channels
      end

      def subscribe_channels
        socket, subscriptions = @subscriptions_mutex.synchronize do
          @subscription_rejected = false
          @pending_subscriptions = @channel_callbacks.each_key.with_index(1).to_h { |channel, id| [id, channel] }
          @session_ready = true
          [@websocket_client, @pending_subscriptions.to_a]
        end
        @ready&.call if subscriptions.empty?
        subscriptions.each do |id, channel|
          frame = "42#{id}#{['subscribe', channel].to_json}"
          debug_log frame
          socket&.send frame
        end
      end

      def acknowledge_subscription(id:, json:)
        channel = @pending_subscriptions[id]
        return unless channel

        error = JSON.parse(json).first
        @pending_subscriptions.delete(id)
        if error
          @subscription_rejected = true
          @subscription_failed&.call(channel, error)
        elsif @pending_subscriptions.empty? && !@subscription_rejected
          @ready&.call
        end
      end

      def receive_pong
        debug_log 'Received pong'
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

      def reset_session
        @subscriptions_mutex.synchronize do
          @session_ready = false
          @pending_subscriptions.clear
          @awaiting_authentication = false
        end
      end
    end
  end
end
