# frozen_string_literal: true

require 'monitor'
require 'openssl'
require 'socket'
require 'timeout'
require 'uri'
require 'websocket/driver'

module Bitflyer
  module Realtime
    class WebSocketTransport
      HANDSHAKE_TIMEOUT = 10

      attr_reader :url

      def initialize(url)
        uri = URI.parse(url)
        raise ArgumentError, 'Realtime connections require TLS' unless %w[https wss].include?(uri.scheme)

        @url = url.sub(/\Ahttps:/, 'wss:')
        @lock = Monitor.new
        @driver = WebSocket::Driver.client(self)
        @driver.on(:close) { @socket.close }
        @socket = connect_tls(uri)
      end

      def on(event, &)
        @driver.on(event, &)
      end

      def start
        @driver.start
        Thread.new { read_messages }
      rescue StandardError
        @socket.close
        raise
      end

      def active?
        !@socket.closed?
      end

      def open?
        active? && @driver.state == :open
      end

      def send(data)
        @lock.synchronize { @driver.text(data) if open? }
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        @socket.close
      end

      def close
        @lock.synchronize { @driver.close if open? }
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        @socket.close
      end

      def write(data)
        @socket.write(data)
      end

      private

      def connect_tls(uri)
        hostname = uri.hostname
        raise ArgumentError, 'Realtime connections require a TLS hostname' unless hostname

        trust_store = OpenSSL::X509::Store.new
        trust_store.set_default_paths
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true, cert_store: trust_store)
        tcp = TCPSocket.new(hostname, uri.port || 443)
        socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
        socket.sync_close = true
        socket.hostname = hostname
        socket.connect
      rescue StandardError
        tcp&.close
        raise
      end

      def read_messages
        read_handshake
        loop do
          data = @socket.readpartial(4096)
          @lock.synchronize { @driver.parse(data) }
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
        failure = e
      ensure
        @socket.close
        @lock.synchronize { @driver.emit(:close, failure) unless @driver.state == :closed }
      end

      def read_handshake
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
        while active? && !open?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout::Error, 'WebSocket upgrade timed out' unless remaining.positive?

          data = Timeout.timeout(remaining) { @socket.readpartial(4096) }
          @lock.synchronize { @driver.parse(data) }
        end
      end
    end
  end
end
