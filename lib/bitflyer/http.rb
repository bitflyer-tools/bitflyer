# frozen_string_literal: true

require 'bitflyer'
require 'bitflyer/http/public'
require 'bitflyer/http/private'
require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module Bitflyer
  module HTTP
    BASE_URL = 'https://api.bitflyer.jp'

    Response = Struct.new(:body)

    class Connection
      def initialize(key, secret)
        @key = key
        @secret = secret
        @uri = URI.parse(BASE_URL)
      end

      def get(path, params = {})
        query = URI.encode_www_form(params.compact)
        full_path = query.empty? ? path : "#{path}?#{query}"
        request = Net::HTTP::Get.new(full_path, default_headers)
        sign_request(request, full_path)
        Response.new(execute(request))
      end

      def post(path, body = {})
        request = Net::HTTP::Post.new(path, default_headers.merge('Content-Type' => 'application/json'))
        request.body = JSON.generate(body.compact)
        sign_request(request, path, request.body)
        Response.new(execute(request))
      end

      private

      def default_headers
        { 'Accept' => 'application/json' }
      end

      def sign_request(request, path, body = '')
        return if @key.nil? || @secret.nil?

        timestamp = Time.now.to_i.to_s
        method = request.method.upcase
        text = timestamp + method + path + (body || '')
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret, text)
        request['ACCESS-KEY'] = @key
        request['ACCESS-TIMESTAMP'] = timestamp
        request['ACCESS-SIGN'] = signature
      end

      def execute(request)
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true) { |http| http.request(request) }
        JSON.parse(response.body)
      rescue JSON::ParserError
        response.body
      end
    end
  end
end
