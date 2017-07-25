require 'bitflyer'
require 'bitflyer/http/public'
require 'bitflyer/http/private'
require 'faraday'
require 'faraday_middleware'
require 'openssl'

module Bitflyer
  module HTTP
    class Connection
      extend Forwardable

      def_delegators :@connection, :get, :post

      def initialize(key, secret)
        @connection = Faraday::Connection.new(:url => 'https://api.bitflyer.jp') do |f|
          f.request :json
          f.response :json
          f.use Authentication, key, secret
          f.adapter Faraday.default_adapter
        end
      end
    end

    class Authentication < Faraday::Middleware
      def initialize(app, key, secret)
        super(app)
        @key = key
        @secret = secret
      end

      def call(env)
        timestamp = Time.now.to_i.to_s
        method = env[:method].to_s.upcase
        path = env[:url].path + (env[:url].query ? '?' + env[:url].query : '')
        body = env[:body] || ''
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret, timestamp +  method + path + body)
        env[:request_headers]['ACCESS-KEY'] = @key if @key
        env[:request_headers]['ACCESS-TIMESTAMP'] = timestamp
        env[:request_headers]['ACCESS-SIGN'] = signature
        @app.call env
      end
    end
  end
end