# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'timeout'
require 'uri'
require 'websocket/driver'

module Bitflyer
  module Realtime
    class Transport
      HANDSHAKE_TIMEOUT = 10
      READ_SIZE = 16 * 1024
      WRITE_TIMEOUT = 10

      attr_reader :url, :thread

      def self.default_ssl_context
        trust_store = OpenSSL::X509::Store.new
        trust_store.set_default_paths
        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true, cert_store: trust_store)
        end
      end

      def initialize(ssl_context: nil)
        @ssl_context = ssl_context
        @driver_lock = Mutex.new
        @close_lock = Mutex.new
        @handlers = {}
        @close_state = nil
      end

      def on(event, &handler)
        @handlers[event] = handler
      end

      def connect(url)
        uri = URI.parse(url)
        raise ArgumentError, 'Realtime connections require TLS' unless %w[https wss].include?(uri.scheme)

        @url = url.sub(/\Ahttps:/, 'wss:')
        @socket = connect_tls(uri)
        setup_driver.start
        @thread = Thread.new { read_messages }
      ensure
        terminate(notify: false) unless @thread
      end

      def open?
        !closed? && @driver&.state == :open
      end

      def closed?
        @socket.nil? || !@close_state.nil?
      end

      def reconnectable?
        @close_state == :closed
      end

      def send(data)
        sent = @driver_lock.synchronize { @driver&.text(data) if open? }
        sent == true && !closed?
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
        terminate(e)
        false
      end

      def close
        @driver_lock.synchronize { @driver&.close if open? }
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
        nil
      ensure
        terminate
      end

      def close_for_shutdown
        terminate
      end

      def write(data)
        socket = @socket
        raise IOError, 'WebSocket is closed' if closed? || !socket

        Timeout.timeout(WRITE_TIMEOUT) { socket.write(data) }
      end

      private

      def setup_driver
        @events = []
        driver = WebSocket::Driver.client(self)
        %i[open message error close].each do |event|
          driver.on(event) { |event_data| @events << [event, event_data] }
        end
        @driver = driver
      end

      def connect_tls(uri)
        hostname = uri.hostname
        raise ArgumentError, 'Realtime connections require a TLS hostname' unless hostname

        context = @ssl_context || self.class.default_ssl_context
        tcp = TCPSocket.new(hostname, uri.port || 443)
        socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
        socket.sync_close = true
        socket.hostname = hostname
        connected = socket.connect
      ensure
        tcp&.close unless connected
      end

      def read_messages
        socket = @socket
        return unless socket

        read_handshake(socket)
        parse(socket.readpartial(READ_SIZE)) until closed?
      rescue EOFError
        nil
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
        failure = e
      ensure
        terminate(failure)
      end

      def read_handshake(socket)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
        until closed? || open?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout::Error, 'WebSocket upgrade timed out' unless remaining.positive?

          parse(Timeout.timeout(remaining) { socket.readpartial(READ_SIZE) })
        end
      end

      def parse(data)
        events = @driver_lock.synchronize do
          @driver&.parse(data)
          @events.shift(@events.size)
        end
        # Callbacks can send messages or shut down the client.
        events.each do |event, payload|
          break if closed?

          case event
          when :error then terminate(payload)
          when :close then terminate
          else @handlers[event]&.call(payload)
          end
        end
      end

      def terminate(error = nil, notify: true)
        closing = false
        socket = @close_lock.synchronize do
          return if @close_state

          closing = true
          @close_state = :closing
          @socket&.close
          @socket
        end
        @handlers[:close]&.call(error, -> { @close_state = :closed }) if socket && notify
      ensure
        @close_state = :closed if closing
      end
    end
  end
end
