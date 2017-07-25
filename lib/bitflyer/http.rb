require 'faraday'
require 'faraday_middleware'

module Bitflyer
  module HTTP
    class Client
      extend Forwardable

      def_delegators :@connection, :get, :post

      def initialize
        @connection = Faraday::Connection.new(:url => 'https://api.bitflyer.jp/v1') do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end
    end

    class Public
      def initialize
        @client = Client.new
      end

      def health
        @client.get('gethealth').body
      end

      def markets
        @client.get('markets').body
      end

      def board(product_code = 'BTC_JPY')
        @client.get('board', { product_code: product_code }).body
      end

      def ticker(product_code = 'BTC_JPY')
        @client.get('ticker', { product_code: product_code }).body
      end

      def executions(product_code = 'BTC_JPY')
        @client.get('executions', { product_code: product_code }).body
      end

      def chats(from_date = (Time.now - 5 * 24 * 60 * 60))
        @client.get('getchats', { from_date: from_date }).body
      end
    end

    class Private

    end
  end
end