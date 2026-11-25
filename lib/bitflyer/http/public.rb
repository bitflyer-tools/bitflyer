# frozen_string_literal: true

module Bitflyer
  module HTTP
    module Public
      class Client
        def initialize
          @connection = Connection.new(nil, nil)
        end

        def close
          @connection.close
        end

        def health(product_code: nil)
          @connection.get('/v1/gethealth', product_code: product_code).body
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

        def funding_rate(product_code:)
          @connection.get('/v1/getfundingrate', product_code: product_code).body
        end

        def funding_rate_history(product_code:, from: nil, to: nil, count: nil)
          query = { product_code: product_code, from: from, to: to, count: count }
          @connection.get('/v1/getfundingratehistory', query).body
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

        def each_execution(
          product_code: 'BTC_JPY', count: nil, before: nil, after: nil, max_pages: IdPagination::DEFAULT_MAX_PAGES,
          &block
        )
          stream = IdPagination.stream(before, max_pages) do |cursor|
            executions(product_code: product_code, count: count, before: cursor, after: after)
          end
          return stream unless block

          stream.each(&block)
          nil
        end

        def chats(from_date: (Time.now - (5 * 24 * 60 * 60)))
          @connection.get('/v1/getchats', from_date: format_from_date(from_date)).body
        end

        private

        def format_from_date(from_date)
          return from_date unless from_date.respond_to?(:strftime)

          from_date.strftime('%Y-%m-%dT%H:%M:%S.%L')
        end
      end
    end
  end
end
