# frozen_string_literal: true

require 'websocket-client-simple'

module Bitflyer
  module Realtime
    class Transport < WebSocket::Client::Simple::Client
      attr_reader :read_error

      READ_SIZE = 16 * 1024
      HEADER_END = "\r\n\r\n".b.freeze

      def connect(url, options = {})
        return if @socket

        @url = url
        socket = connect_socket(URI.parse(url), options)
        ::WebSocket.should_raise = true
        @handshake = ::WebSocket::Handshake::Client.new(url: url, headers: options[:headers])
        @handshaked = @pipe_broken = @closed = false
        once :__close do |error|
          close
          emit :close, error
        end

        socket.write(@handshake.to_s)
        @thread = Thread.new { receive_frames(socket) }
      end

      def close_after_read_error(error)
        @read_error = error
        close_for_shutdown
      end

      def close_after_write_reset(error)
        @pipe_broken = true
        emit :__close, error
      end

      def close_for_shutdown
        # A close frame can block on the same socket as the pending write.
        @pipe_broken = true
        Thread.current == thread ? close_from_reader : close
      end

      private

      def connect_socket(uri, options)
        host = uri.host || raise(ArgumentError, 'WebSocket URL must include a host')
        socket = @socket = TCPSocket.new(host, uri.port || (uri.scheme == 'wss' ? 443 : 80))
        return socket unless %w[https wss].include?(uri.scheme)

        tls = @socket = OpenSSL::SSL::SSLSocket.new(socket, ssl_context(options))
        tls.sync_close = true
        tls.hostname = host
        tls.connect
        tls
      end

      def ssl_context(options)
        context = OpenSSL::SSL::SSLContext.new
        context.ssl_version = options[:ssl_version] if options[:ssl_version]
        context.verify_mode = options[:verify_mode] if options[:verify_mode]
        store = options[:cert_store] || OpenSSL::X509::Store.new
        store.set_default_paths
        context.cert_store = store
        context
      end

      def receive_frames(socket)
        headers = ''.b
        frame = ::WebSocket::Frame::Incoming::Client.new
        until @closed
          begin
            chunk = read_chunk(socket)
            break unless chunk

            process_chunk(headers, frame, chunk)
          rescue StandardError => e
            emit :error, e unless @closed
          end
        end
      end

      def read_chunk(socket)
        socket.readpartial(READ_SIZE)
      rescue EOFError
        close_from_reader
        nil
      end

      def process_chunk(headers, frame, chunk)
        chunk = receive_upgrade(headers, chunk) unless @handshaked
        deliver_frames(frame, chunk) if chunk && !@closed
      end

      def receive_upgrade(headers, chunk)
        offset = [0, headers.bytesize - HEADER_END.bytesize + 1].max
        headers << chunk
        boundary = headers.index(HEADER_END, offset)
        return unless boundary

        length = boundary + HEADER_END.bytesize
        @handshake << headers.byteslice(0, length).to_s
        remaining = headers.byteslice(length..)
        headers.clear
        @handshaked = true
        emit :open
        remaining
      end

      def deliver_frames(frame, chunk)
        frame << chunk
        while !@closed && (message = frame.next)
          emit :message, message
        end
      end

      def close_from_reader
        return if @closed

        # The read loop exits after the current callback returns.
        @closed = @pipe_broken = true
        @socket&.close
        @socket = nil
        emit :__close
      end
    end
  end
end
