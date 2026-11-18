# frozen_string_literal: true

require 'websocket-client-simple'

module Bitflyer
  module Realtime
    class Transport < WebSocket::Client::Simple::Client
      attr_reader :reset_error

      def close_after_reset(error)
        @reset_error = error
        @pipe_broken = true
        close
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
    end
  end
end
