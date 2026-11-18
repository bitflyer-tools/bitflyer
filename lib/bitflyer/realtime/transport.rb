# frozen_string_literal: true

require 'websocket-client-simple'

module Bitflyer
  module Realtime
    class Transport < WebSocket::Client::Simple::Client
      attr_reader :read_error

      def connect(url, options = {})
        super
      rescue NoMethodError => e
        # The receiver can clear the socket before the handshake request is written.
        error = @read_error
        raise unless error && e.name == :write && e.receiver.nil?

        raise error
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

      def close_on_eof
        socket = @socket
        return unless socket

        transport = self
        read_byte = socket.method(:getc)
        # The upstream reader retries forever when getc returns EOF.
        socket.define_singleton_method(:getc) do
          byte = read_byte.call
          transport.close if byte.nil?
          byte
        end
      end

      private

      def close_from_reader
        return if @closed

        # The read loop exits after the current callback returns.
        @closed = true
        @socket&.close
        @socket = nil
        emit :__close
      end
    end
  end
end
