# frozen_string_literal: true

require 'json'
require 'openssl'
require 'securerandom'

module Bitflyer
  module Realtime
    class SocketIOSession
      RESPONSE_TIMEOUT_MS = 10_000
      private_constant :RESPONSE_TIMEOUT_MS

      def initialize(connection, heartbeat, subscriptions, dispatcher, credentials, log)
        @connection = connection
        @heartbeat = heartbeat
        @subscriptions = subscriptions
        @dispatcher = dispatcher
        @key, @secret = credentials
        @log = log
      end

      def opened
        @session_deadline = [monotonic_milliseconds + RESPONSE_TIMEOUT_MS, :setup]
      end

      def reset = @awaiting_authentication = false

      def replace
        reset
        @session_deadline = nil
      end

      def handle_message(payload:, socket: @connection.transport) # rubocop:disable Metrics/CyclomaticComplexity
        return if @connection.synchronize { @connection.inactive? }

        prefix = /\A\d+/.match(payload.data)
        return unless prefix

        code = prefix[0]
        @log.call "Received packet #{code}"

        case code
        when '0' then setup_by_response(json: prefix.post_match, socket: socket)
        when '3' then @heartbeat.receive_pong(socket: socket)
        when '41' then @connection.disconnect(socket: socket)
        when '42' then emit_message(json: prefix.post_match, socket: socket)
        when '430' then authenticated(json: prefix.post_match, socket: socket)
        when /\A43[1-9]\d*\z/
          @subscriptions.acknowledge_subscription(id: code[2..].to_i, json: prefix.post_match, socket: socket)
        end
      rescue JSON::ParserError
        puts 'Invalid JSON in realtime frame'
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def setup_by_response(json:, socket: @connection.transport)
        return unless apply_setup(JSON.parse(json), socket)

        if @key && @secret
          authenticate(socket: socket)
        else
          @subscriptions.subscribe_channels(socket: socket)
        end
      end

      def authenticated(json:, socket: @connection.transport)
        return unless accept_authentication_response(socket)
        return reject_authentication(json, socket: socket) unless authentication_succeeded?(json)

        @log.call 'Authenticated'
        @subscriptions.subscribe_channels(socket: socket, authenticated: true)
      end

      def authentication_succeeded?(json)
        arguments = JSON.parse(json)
        arguments.is_a?(Array) && arguments.first.nil?
      rescue JSON::ParserError
        false
      end

      def session_expired?(socket)
        stage = @connection.synchronize do
          deadline = @session_deadline
          return false if @connection.inactive? || !@connection.transport.equal?(socket) || !deadline.is_a?(Array)
          return false unless session_deadline_elapsed?(deadline)

          @session_deadline = :expired
          deadline[1]
        end
        @log.call "Timed out waiting for Socket.IO #{stage} response"
        socket.close
        true
      end

      def authenticate(socket: @connection.transport)
        @log.call 'Authenticate'
        timestamp = Time.now.to_i
        nonce = SecureRandom.hex(16)
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret.to_s, timestamp.to_s + nonce)
        auth_params = {
          api_key: @key,
          timestamp: timestamp,
          nonce: nonce,
          signature: signature
        }
        @connection.synchronize do
          return if !@connection.transport.equal?(socket) || @awaiting_authentication
          return unless @subscriptions.before_start { @awaiting_authentication = true }
        end
        socket&.send "420#{['auth', auth_params].to_json}"
      end

      def emit_message(json:, socket: @connection.transport)
        channel_name, *messages = JSON.parse(json)
        return unless channel_name

        @log.call("Received event on #{channel_name}")
        @subscriptions.deliver(channel_name.to_sym, messages, socket)
      end

      private

      def accept_authentication_response(socket)
        @connection.synchronize do
          return false if @connection.inactive? || !@connection.transport.equal?(socket)

          deadline = @session_deadline
          return false unless deadline.is_a?(Array) && deadline[1] == :authentication
          return false if session_deadline_elapsed?(deadline) || !@awaiting_authentication

          @awaiting_authentication = false
          @session_deadline = :established
          true
        end
      end

      def reject_authentication(json, socket:)
        error = @connection.synchronize do
          return if @connection.inactive? || !@connection.transport.equal?(socket)

          @connection.reject_authentication
          @dispatcher.stop
          @subscriptions.reset_for(socket) do
            reset
            @heartbeat.clear_pending
          end
          RuntimeError.new("Authentication failed: #{json}")
        end

        begin
          @connection.disconnect(socket: socket)
        rescue SystemCallError, IOError => e
          @log.call(e)
        ensure
          @dispatcher.notify_authentication_failure(error)
        end
      end

      def apply_setup(body, socket)
        @connection.synchronize do
          return false if @connection.inactive? || !@connection.transport.equal?(socket)

          return false unless awaiting_setup?(@session_deadline)

          @heartbeat.setup(body)
          @session_deadline = authentication_deadline || :established
          true
        end
      end

      def awaiting_setup?(deadline)
        return true if deadline.nil?

        deadline.is_a?(Array) && deadline[1] == :setup && !session_deadline_elapsed?(deadline)
      end

      def authentication_deadline
        [monotonic_milliseconds + RESPONSE_TIMEOUT_MS, :authentication] if @key && @secret
      end

      def session_deadline_elapsed?(deadline)
        monotonic_milliseconds >= deadline[0]
      end

      def monotonic_milliseconds = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end
  end
end
