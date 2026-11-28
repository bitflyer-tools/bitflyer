# frozen_string_literal: true

module Bitflyer
  module Realtime
    class ConnectionAttempt
      TIMEOUT = 10
      private_constant :TIMEOUT

      attr_reader :transport

      def initialize(transport, url)
        @transport = transport
        @connector = Thread.new do
          transport.connect(url)
          nil
        rescue StandardError => e
          e
        end
      end

      def established?(log)
        unless @connector.join(TIMEOUT)
          log.call('Timed out establishing the WebSocket transport')
          return false
        end

        error = @connector.value
        raise error if error

        true
      end

      def cancel
        @connector.kill
      end

      def close(unless_transport: nil)
        @connector.join
        @transport.close_for_shutdown unless @transport.equal?(unless_transport)
      end
    end
  end
end
