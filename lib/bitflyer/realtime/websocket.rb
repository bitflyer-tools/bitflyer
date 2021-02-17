# frozen_string_literal: true

require 'websocket-client-simple'
require 'json'

module Bitflyer
  module Realtime
    class WebSocketClient
      attr_accessor :websocket_client, :channel_names, :channel_callbacks, :ping_interval, :ping_timeout,
                    :last_ping_at, :last_pong_at

      def initialize(host:, debug: false)
        @host = host
        @debug = debug
        @channel_names = []
        @channel_callbacks = {}
        connect
        start_monitoring
      end

      def subscribe(channel_name:, &block)
        debug_log "Subscribe #{channel_name}"
        @channel_names = (@channel_names + [channel_name]).uniq
        @channel_callbacks[channel_name] = block
        websocket_client.send "42#{['subscribe', channel_name].to_json}"
      end

      def connect
        @websocket_client = WebSocket::Client::Simple.connect "#{@host}/socket.io/?transport=websocket"
        this = self
        @websocket_client.on(:message) { |payload| this.handle_message(payload: payload) }
        @websocket_client.on(:error) { |error| this.handle_error(error: error) }
      rescue SocketError => e
        puts e
        puts e.backtrace.join("\n")
      end

      def start_monitoring
        Thread.new do
          loop do
            sleep 1
            if @websocket_client&.open?
              send_ping
              wait_pong
            end
          end
        end

        Thread.new do
          loop do
            sleep 1
            next if @websocket_client&.open?

            reconnect
          end
        end
      end

      def send_ping
        return unless @last_ping_at && @ping_interval
        return unless Time.now.to_i - @last_ping_at > @ping_interval / 1000

        debug_log 'Sent ping'
        @websocket_client.send '2'
        @last_ping_at = Time.now.to_i
      end

      def wait_pong
        return unless @last_pong_at && @ping_timeout
        return unless Time.now.to_i - @last_pong_at > (@ping_interval + @ping_timeout) / 1000

        debug_log 'Timed out waiting pong'
        @websocket_client.close
      end

      def reconnect
        return if @websocket_client&.open?

        debug_log 'Reconnecting...'

        @websocket_client.close if @websocket_client.open?
        connect
      end

      def handle_error(error:)
        debug_log error
        return unless error.is_a? Errno::ECONNRESET

        reconnect
      end

      def handle_message(payload:)
        debug_log payload.data
        return unless payload.data =~ /^\d+/

        code, body = payload.data.scan(/^(\d+)(.*)$/)[0]

        case code.to_i
        when 0 then setup_by_response(json: body)
        when 3 then receive_pong
        when 41 then disconnect
        when 42 then emit_message(json: body)
        end
      rescue StandardError => e
        puts e
        puts e.backtrace.join("\n")
      end

      def setup_by_response(json:)
        body = JSON.parse json
        @ping_interval = body['pingInterval'].to_i || 25_000
        @ping_timeout  = body['pingTimeout'].to_i || 60_000
        @last_ping_at = Time.now.to_i
        @last_pong_at = Time.now.to_i
        channel_callbacks.each do |channel_name, _|
          websocket_client.send "42#{['subscribe', channel_name].to_json}"
        end
      end

      def receive_pong
        debug_log 'Received pong'
        @last_pong_at = Time.now.to_i
      end

      def disconnect
        debug_log 'Disconnecting from server...'
        websocket_client.close
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
    end
  end
end
