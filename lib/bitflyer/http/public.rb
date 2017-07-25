module Bitflyer
  module HTTP
    module Public
      class Client
        def initialize
          @connection = Connection.new
        end

        def health
          @connection.get('gethealth').body
        end

        def markets
          @connection.get('markets').body
        end

        def board(product_code = 'BTC_JPY')
          @connection.get('board', { product_code: product_code }).body
        end

        def ticker(product_code = 'BTC_JPY')
          @connection.get('ticker', { product_code: product_code }).body
        end

        def executions(product_code = 'BTC_JPY')
          @connection.get('executions', { product_code: product_code }).body
        end

        def chats(from_date = (Time.now - 5 * 24 * 60 * 60))
          @connection.get('getchats', { from_date: from_date }).body
        end
      end
    end
  end
end