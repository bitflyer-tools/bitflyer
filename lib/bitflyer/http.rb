require 'bitflyer'
require 'bitflyer/http/public'
require 'bitflyer/http/private'
require 'faraday'
require 'faraday_middleware'

module Bitflyer
  module HTTP
    class Connection
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
  end
end