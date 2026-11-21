# frozen_string_literal: true

require 'json'
require 'openssl'
require 'bitflyer/realtime/transport'
require_relative 'order_book'

module Bitflyer
  module Realtime
    class WebSocketClient # rubocop:disable Metrics/ClassLength
      CONNECTION_TIMEOUT = 10
      SESSION_RESPONSE_TIMEOUT_MS = 10_000
      CALLBACK_QUEUE_LIMIT = 1_024
      SUBSCRIPTION_ACK_TIMEOUT_MS = 10_000
      RECONNECT_BASE_DELAY = 1.0
      RECONNECT_MAX_DELAY = 30.0
      private_constant :CONNECTION_TIMEOUT, :SESSION_RESPONSE_TIMEOUT_MS, :CALLBACK_QUEUE_LIMIT,
                       :SUBSCRIPTION_ACK_TIMEOUT_MS, :RECONNECT_BASE_DELAY, :RECONNECT_MAX_DELAY

      attr_accessor :channel_names, :channel_callbacks, :ping_interval, :ping_timeout, :subscription_failed
      attr_reader :websocket_client, :ready, :disconnected, :last_ping_at, :last_pong_at

      def initialize(host:, key:, secret:, debug: false)
        @host = host
        @key = key
        @secret = secret
        @debug = debug
        @channel_names = []
        @channel_callbacks = {}
        @order_books = {}
        @board_feeds = {}
        @lifecycle_lock = Mutex.new
        @shutdown_lock = Mutex.new
        @monitor_wakeup = ConditionVariable.new
        initialize_callbacks
        @stopped = false
        @reconnect_delay = nil
        @authentication_error = @pending_authentication_error = nil
        @session_mutex = Thread::Mutex.new
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

      def disconnected=(callback)
        error = @lifecycle_lock.synchronize do
          @disconnected = callback
          next unless callback

          pending_error = @pending_authentication_error
          @pending_authentication_error = nil
          pending_error
        end
        notify_disconnected(error, callback) if error && callback
        callback
      end

      def subscribe(channel_name:, &block)
        debug_log "Subscribe #{channel_name}"
        @session_mutex.synchronize do
          @channel_names = (@channel_names + [channel_name]).uniq
          @subscription_tokens[channel_name] ||= Object.new
          @channel_callbacks[channel_name] = block
          queue_subscription(channel_name)
        end
        send_subscription_frames
      end

      def order_book(product_code:)
        book = @session_mutex.synchronize do
          @order_books[product_code] ||= register_order_book(product_code)
        end
        send_subscription_frames
        book
      end

      def unsubscribe(channel_name:)
        socket = @lifecycle_lock.synchronize do
          @session_mutex.synchronize do
            return unless @channel_callbacks.key?(channel_name)

            @channel_callbacks.delete(channel_name)
            @subscription_tokens.delete(channel_name)
            @callback_queue.delete_if { |channel,| channel == channel_name }
            return if @board_feeds.key?(channel_name)

            @channel_names -= [channel_name]
            @pending_subscriptions.delete_if { |_id, (channel, _deadline)| channel == channel_name }
            @acknowledged_subscriptions.delete(channel_name)
            queue_subscription_frame("42#{['unsubscribe', channel_name].to_json}") if @session_ready
            @websocket_client
          end
        end
        send_subscription_frames
        notify_ready(socket)
      end

      def connect
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
        return unless socket
        return if socket.send('2') == false

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

        prefix = /\A\d+/.match(payload.data)
        return unless prefix

        code = prefix[0]
        debug_log "Received packet #{code}"

        case code
        when '0' then setup_by_response(json: prefix.post_match, socket: socket)
        when '3' then receive_pong
        when '41' then disconnect(socket: socket)
        when '42' then emit_message(json: prefix.post_match, socket: socket)
        when '430' then authenticated(json: prefix.post_match, socket: socket)
        when /\A43[1-9]\d*\z/
          acknowledge_subscription(id: code[2..].to_i, json: prefix.post_match, socket: socket)
        end
      rescue JSON::ParserError
        puts 'Invalid JSON in realtime frame'
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def handle_close(error:, socket: @websocket_client, complete_close: nil)
        debug_log error
        callback = @lifecycle_lock.synchronize do
          connecting_socket = @connection&.first
          next if lifecycle_inactive? || !(reset_readiness(socket) || (socket && connecting_socket.equal?(socket)))

          # Keep retries gated until the previous session has been invalidated.
          complete_close&.call
          @disconnected
        end
        dispatch_disconnected(error, callback)
      end

      def setup_by_response(json:, socket: @websocket_client)
        return unless apply_setup(JSON.parse(json), socket)

        if @key && @secret
          authenticate(socket: socket)
        else
          subscribe_channels(socket: socket)
        end
      end

      def authenticate(socket: @websocket_client)
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
        @session_mutex.synchronize do
          return if !@websocket_client.equal?(socket) || @awaiting_authentication || @session_ready

          @awaiting_authentication = true
        end
        socket&.send "420#{['auth', auth_params].to_json}"
      end

      def authenticated(json:, socket: @websocket_client)
        return unless accept_authentication_response(socket)
        return reject_authentication(json, socket: socket) unless authentication_succeeded?(json)

        debug_log 'Authenticated'
        subscribe_channels(socket: socket)
      end

      def authentication_succeeded?(json)
        arguments = JSON.parse(json)
        arguments.is_a?(Array) && arguments.first.nil?
      rescue JSON::ParserError
        false
      end

      def subscribe_channels(socket: @websocket_client)
        @session_mutex.synchronize do
          return if !@websocket_client.equal?(socket) || @session_ready

          @session_ready = true
          (@board_feeds.keys | @channel_callbacks.keys).each { |channel| queue_subscription(channel, setup: true) }
          @last_setup_subscription_id = @next_subscription_id
          unless @pending_subscriptions.empty?
            @subscription_ack_deadline = monotonic_milliseconds + SUBSCRIPTION_ACK_TIMEOUT_MS
          end
        end
        send_subscription_frames
        notify_ready(socket)
      end

      def acknowledge_subscription(id:, json:, socket: @websocket_client)
        channel, error = @session_mutex.synchronize do
          return unless @websocket_client.equal?(socket)

          pending = @pending_subscriptions[id]
          return unless pending

          channel = pending.first
          error = JSON.parse(json).first
          @pending_subscriptions.delete(id)
          record_subscription_result(id, channel, error)
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

      def disconnect(socket: @websocket_client)
        debug_log 'Disconnecting from server...'
        socket&.close
      end

      def emit_message(json:, socket: @websocket_client)
        channel_name, *messages = JSON.parse json
        return unless channel_name

        debug_log "Received event on #{channel_name}"
        channel = channel_name.to_sym
        route_messages(channel, messages, socket) do |token|
          messages.each { |message| enqueue_callback(channel, token, message, socket) }
        end
      end

      def debug_log(message)
        return unless @debug

        p message
      end

      private

      def initialize_callbacks
        @subscription_tokens = {}
        @callback_queue = []
        @callback_transport = nil
        @callback_wakeup = ConditionVariable.new
        @callback_worker = nil
      end

      def enqueue_callback(channel, token, message, socket)
        @lifecycle_lock.synchronize do
          return unless active_callback_transport?(socket)
          return if @callback_queue.size >= CALLBACK_QUEUE_LIMIT
          return unless subscribed_callback(channel, token)

          @callback_worker ||= Thread.new { deliver_callbacks }
          @callback_queue << [channel, token, message, socket]
          @callback_wakeup.signal
        end
      end

      def deliver_callbacks
        while (event = next_callback_event)
          deliver_callback(*event)
        end
      end

      def next_callback_event
        @lifecycle_lock.synchronize do
          @callback_wakeup.wait(@lifecycle_lock) while @callback_queue.empty? && !lifecycle_inactive?
          @callback_queue.shift
        end
      end

      def deliver_callback(channel, token, message, socket)
        callback = @lifecycle_lock.synchronize do
          subscribed_callback(channel, token) if active_callback_transport?(socket)
        end
        callback&.call(message)
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def active_callback_transport?(socket)
        !lifecycle_inactive? && !socket.nil? && @callback_transport.equal?(socket) && !socket.closed?
      end

      def subscribed_callback(channel, token)
        @session_mutex.synchronize do
          @channel_callbacks[channel] if @subscription_tokens[channel].equal?(token)
        end
      end

      def stop_callbacks
        @callback_queue.clear
        @callback_wakeup.signal
      end

      def record_subscription_result(id, channel, error)
        if error
          @subscription_rejected = true if id <= @last_setup_subscription_id
        else
          @acknowledged_subscriptions[channel] = true
        end
      end

      def register_order_book(product_code)
        book = OrderBook.new
        delta_channel = :"lightning_board_#{product_code}"
        # Start receiving deltas before requesting the snapshot.
        register_board_feed(delta_channel, book.method(:update), delta_channel)
        register_board_feed(:"lightning_board_snapshot_#{product_code}", book.method(:replace), delta_channel)
        book
      end

      def register_board_feed(channel, handler, delta_channel)
        @board_feeds[channel] = [handler, delta_channel]
        @channel_names = (@channel_names + [channel]).uniq
        queue_subscription(channel)
      end

      def route_messages(channel, messages, socket)
        token = @session_mutex.synchronize do
          return unless @websocket_client.equal?(socket)

          route_board_messages(channel, messages)
          return unless @channel_callbacks[channel]

          @subscription_tokens[channel]
        end
        yield token
      end

      def route_board_messages(channel, messages)
        feed = @board_feeds[channel]
        return unless feed

        handler, delta_channel = feed
        return unless @acknowledged_subscriptions.key?(delta_channel)

        messages.each { |message| handler.call(message) }
      end

      def queue_subscription(channel, setup: false)
        return unless @session_ready
        return if @acknowledged_subscriptions.key?(channel)
        return if @pending_subscriptions.each_value.any? { |pending| pending.first == channel }

        @next_subscription_id += 1
        deadline = monotonic_milliseconds + SUBSCRIPTION_ACK_TIMEOUT_MS unless setup
        @pending_subscriptions[@next_subscription_id] = [channel, deadline]
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
          stop_callbacks
          reset_readiness
          @monitor_wakeup.signal
          @connection&.last&.kill
          [@websocket_client, @connection]
        end
      end

      def start_connection
        @lifecycle_lock.synchronize do
          socket = @websocket_client
          return if lifecycle_inactive? || @connection || (socket && !socket.reconnectable?)

          reset_readiness(socket)
          advance_reconnect_delay
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
        transport.on(:close) do |error, complete_close|
          this.handle_close(error: error, socket: transport, complete_close: complete_close)
        end
      end

      def activate_transport(transport)
        @lifecycle_lock.synchronize do
          return if lifecycle_inactive?
          return unless @connection&.first.equal?(transport) || @websocket_client.equal?(transport)

          replace_transport(transport)
          @session_deadline = [monotonic_milliseconds + SESSION_RESPONSE_TIMEOUT_MS, :setup]
        end
      end

      def replace_transport(transport)
        return if @websocket_client.equal?(transport)

        @ping_interval = @ping_timeout = nil
        @session_deadline = nil
        self.last_ping_at = self.last_pong_at = nil
        @session_mutex.synchronize do
          @websocket_client = transport
          @callback_transport = transport
          @callback_queue.clear
          clear_readiness
        end
      end

      def finish_connection(connection, connected)
        transport, connector = connection
        close_transport = @lifecycle_lock.synchronize do
          @connection = nil
          return if @stopped

          replace_transport(transport) if connected && !@authentication_error
          !connected
        end
        return unless close_transport

        connector.kill
        connector.join
        transport.close_for_shutdown
      end

      def start_monitoring
        Thread.new do
          while (tick = wait_for_monitor_tick)
            case tick
            when :retry then reconnect
            when :poll then poll_transport
            end
          end
        end
      end

      def accept_authentication_response(socket)
        @lifecycle_lock.synchronize do
          return false unless @websocket_client.equal?(socket)

          deadline = @session_deadline
          return false if lifecycle_inactive? || !deadline.is_a?(Array) || deadline[1] != :authentication
          return false if session_deadline_elapsed?(deadline)

          @session_mutex.synchronize do
            return false unless @awaiting_authentication

            @awaiting_authentication = false
            @session_deadline = :established
          end
          true
        end
      end

      def apply_setup(body, socket)
        @lifecycle_lock.synchronize do
          return false if lifecycle_inactive? || !@websocket_client.equal?(socket)

          return false unless awaiting_setup?(@session_deadline)

          initialize_heartbeat(body)
          @session_deadline = authentication_deadline || :established
          true
        end
      end

      def awaiting_setup?(deadline)
        return true if deadline.nil?

        deadline.is_a?(Array) && deadline[1] == :setup && !session_deadline_elapsed?(deadline)
      end

      def authentication_deadline
        [monotonic_milliseconds + SESSION_RESPONSE_TIMEOUT_MS, :authentication] if @key && @secret
      end

      def initialize_heartbeat(body)
        @ping_interval = body['pingInterval']&.to_i || 25_000
        @ping_timeout = body['pingTimeout']&.to_i || 60_000
        @last_ping_at = @last_pong_at = Time.now.to_i
        @last_ping_monotonic = @last_pong_monotonic = monotonic_milliseconds
      end

      def session_expired?(socket)
        stage = @lifecycle_lock.synchronize do
          deadline = @session_deadline
          return false if lifecycle_inactive? || !@websocket_client.equal?(socket) || !deadline.is_a?(Array)
          return false unless session_deadline_elapsed?(deadline)

          @session_deadline = :expired
          deadline[1]
        end
        debug_log "Timed out waiting for Socket.IO #{stage} response"
        socket.close
        true
      end

      def session_deadline_elapsed?(deadline)
        monotonic_milliseconds >= deadline[0]
      end

      def close_expired_subscriptions
        socket = @session_mutex.synchronize do
          deadline = @subscription_ack_deadline
          return unless deadline && monotonic_milliseconds >= deadline && setup_subscriptions_pending?

          @subscription_ack_deadline = nil
          @subscription_rejected = true
          @pending_subscriptions.clear
          @websocket_client
        end
        debug_log 'Timed out waiting for setup subscription acknowledgments'
        socket&.close
      end

      def expire_runtime_subscriptions(socket)
        expired = @session_mutex.synchronize do
          return unless @websocket_client.equal?(socket) && socket.open?

          now = monotonic_milliseconds
          pending = @pending_subscriptions.select { |_id, (_channel, deadline)| deadline && now >= deadline }
          pending.each_key { |id| @pending_subscriptions.delete(id) }
          pending
        end
        expired.each_value { |channel, _deadline| notify_subscription_timeout(channel) }
      end

      def notify_subscription_timeout(channel)
        @subscription_failed&.call(channel, 'Timed out waiting for subscription acknowledgment')
      rescue StandardError => e
        puts e
        puts e.backtrace&.join("\n")
      end

      def wait_for_monitor_tick
        @lifecycle_lock.synchronize do
          return if lifecycle_inactive?

          retrying = retry_pending?
          @monitor_wakeup.wait(@lifecycle_lock, retrying ? jittered_reconnect_delay : 1)
          (retrying ? :retry : :poll) unless lifecycle_inactive?
        end
      end

      def retry_pending?
        socket = @websocket_client
        !@connection && (!socket || socket.reconnectable?)
      end

      def poll_transport
        socket = @websocket_client
        return unless socket&.open?
        return if session_expired?(socket)

        send_ping
        wait_pong
        close_expired_subscriptions
        expire_runtime_subscriptions(socket)
      end

      def advance_reconnect_delay
        delay = @reconnect_delay
        @reconnect_delay = delay ? [delay * 2, RECONNECT_MAX_DELAY].min : RECONNECT_BASE_DELAY
      end

      def jittered_reconnect_delay
        (@reconnect_delay || RECONNECT_BASE_DELAY) * (0.5 + (rand * 0.5))
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

            if @ready_state == :pending
              @reconnect_delay = RECONNECT_BASE_DELAY
              @ready_state = :ready
            end
            take_ready_callback
          end
        end
        notification&.call
      end

      def setup_subscriptions_acknowledged?
        !@subscription_rejected && !setup_subscriptions_pending?
      end

      def setup_subscriptions_pending?
        @pending_subscriptions.each_key.any? { |id| id <= @last_setup_subscription_id }
      end

      def take_ready_callback
        return unless @ready_state == :ready && @ready
        return if @websocket_client&.closed?

        @ready_state = :notified
        @ready
      end

      def reset_readiness(socket = @websocket_client)
        @session_mutex.synchronize do
          return false unless @websocket_client.equal?(socket)

          @callback_transport = nil
          @callback_queue.clear
          clear_readiness
          true
        end
      end

      def clear_readiness
        @order_books.each_value(&:invalidate)
        @subscription_frames = []
        @next_subscription_id = @last_setup_subscription_id = 0
        @pending_subscriptions = {}
        @acknowledged_subscriptions = {}
        @subscription_ack_deadline = nil
        @subscription_rejected = false
        @awaiting_authentication = false
        @session_ready = false
        @ready_state = :pending
      end

      def reject_authentication(json, socket: @websocket_client)
        error = @lifecycle_lock.synchronize do
          return if lifecycle_inactive? || !@websocket_client.equal?(socket)

          failure = RuntimeError.new("Authentication failed: #{json}")
          @authentication_error = failure
          stop_callbacks
          reset_readiness
          @monitor_wakeup.signal
          failure
        end

        begin
          disconnect(socket: socket)
        rescue SystemCallError, IOError => e
          debug_log e
        ensure
          notify_authentication_failure(error)
        end
      end

      def notify_authentication_failure(error)
        callback = @lifecycle_lock.synchronize do
          @pending_authentication_error = error unless @disconnected
          @disconnected
        end
        dispatch_disconnected(error, callback)
      end

      def dispatch_disconnected(error, callback)
        Thread.new { notify_disconnected(error, callback) } if callback
      end

      def notify_disconnected(error, callback)
        callback.call(error)
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
