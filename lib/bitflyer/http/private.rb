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

        def addresses
          @connection.get('/v1/me/getaddresses').body
        end

        def coin_ins
          @connection.get('/v1/me/getcoinins').body
        end

        def coin_outs
          @connection.get('/v1/me/getcoinouts').body
        end

        def bank_accounts
          @connection.get('/v1/me/getbankaccounts').body
        end

        def deposits
          @connection.get('/v1/me/getdeposits').body
        end

        def withdraw
          # TBD
        end

        def withdrawals
          @connection.get('/v1/me/getwithdrawals').body
        end

        def positions
          @connection.get('/v1/me/getpositions', { product_code: 'FX_BTC_JPY' }).body
        end
      end
    end
  end
end