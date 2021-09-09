# frozen_string_literal: true

module Bitflyer
  module HTTP
    module Public
      class Client
        def initialize
          @connection = Connection.new(nil, nil)
        end

        def health
          @connection.get('/v1/gethealth').body
        end

        def markets
          @connection.get('/v1/markets').body
        end

        def board(product_code: 'BTC_JPY')
          @connection.get('/v1/board', product_code: product_code).body
        end

        def ticker(product_code: 'BTC_JPY')
          @connection.get('/v1/ticker', product_code: product_code).body
        end

        def executions(product_code: 'BTC_JPY', count: nil, before: nil, after: nil)
          query = {
            product_code: product_code,
            count: count,
            before: before,
            after: after
          }.delete_if { |_, v| v.nil? }
          @connection.get('/v1/executions', query).body
        end

        def chats(from_date: (Time.now - (5 * 24 * 60 * 60)))
          @connection.get('/v1/getchats', from_date: from_date).body
        end
      end
    end
  end
end
