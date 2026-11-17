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
        @mutex = Mutex.new
        @http = nil
      end

      def close
        @mutex.synchronize { close_session }
      end

      def get(path, params = {})
        query = URI.encode_www_form(params.compact)
        full_path = query.empty? ? path : "#{path}?#{query}"
        request = Net::HTTP::Get.new(full_path, default_headers)
        Response.new(execute(request))
      end

      def post(path, body = {})
        request = Net::HTTP::Post.new(path, default_headers.merge('Content-Type' => 'application/json'))
        request.body = JSON.generate(body.compact)
        Response.new(execute(request))
      end

      private

      def default_headers
        { 'Accept' => 'application/json' }
      end

      def sign_request(request, path, body = '')
        key = @key
        secret = @secret
        return if key.nil? || secret.nil?

        timestamp = Time.now.to_i.to_s
        method = request.method.upcase
        text = timestamp + method + path + (body || '')
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, text)
        request['ACCESS-KEY'] = key
        request['ACCESS-TIMESTAMP'] = timestamp
        request['ACCESS-SIGN'] = signature
      end

      def execute(request)
        response = @mutex.synchronize { send_request(request) }
        parse_body(response.body)
      end

      def send_request(request)
        http = (@http ||= Net::HTTP.start(@uri.host.to_s, @uri.port, use_ssl: true))
        sign_request(request, request.path, request.body)
        # Net::HTTP reconnects idle sockets and only retries idempotent requests.
        http.request(request)
      rescue StandardError
        close_session
        raise
      end

      def close_session
        http = @http
        @http = nil
        http&.finish
      end

      def parse_body(body)
        JSON.parse(body)
      rescue JSON::ParserError
        body
      end
    end
  end
end
