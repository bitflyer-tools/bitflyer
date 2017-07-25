module Bitflyer
  module HTTP
    module Private
      class Client
        def initialize(key, secret)
          @connection = Connection.new(key, secret)
        end

        def permissions
          @connection.get('/v1/me/getpermissions').body
        end

        def balance
          @connection.get('/v1/me/getbalance').body
        end

        def collateral
          @connection.get('/v1/me/getcollateral').body
        end

        def positions
          @connection.get('/v1/me/getpositions', { product_code: 'FX_BTC_JPY' }).body
        end
      end
    end
  end
end