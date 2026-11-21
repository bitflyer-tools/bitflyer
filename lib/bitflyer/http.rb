# frozen_string_literal: true

require 'bitflyer/http/public'
require 'bitflyer/http/private'
require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module Bitflyer
  module HTTP
    BASE_URL = 'https://api.bitflyer.jp'
    MAX_RESPONSE_BODY_BYTES = 10 * 1024 * 1024

    Response = Struct.new(:body)

    module ExecutionHistory
      DEFAULT_MAX_PAGES = 10

      def self.stream(before, max_pages)
        validate_page_budget(max_pages)

        Enumerator.new do |yielder|
          cursor = before
          max_pages.times do
            page = yield(cursor)
            break if page.empty?

            next_cursor = page.map { |execution| execution.fetch('id') }.min
            break if cursor && next_cursor >= cursor

            page.each { |execution| yielder << execution }
            cursor = next_cursor
          end
        end
      end

      def self.validate_page_budget(max_pages)
        return if max_pages.is_a?(Integer) && max_pages >= 0

        raise ArgumentError, 'max_pages must be a non-negative integer'
      end
      private_class_method :validate_page_budget
    end
    private_constant :ExecutionHistory

    class ResponseError < StandardError
      attr_reader :status, :body

      def initialize(status, body)
        @status = status
        @body = body
        super("bitFlyer API returned HTTP #{status}")
      end
    end

    class ResponseTooLargeError < StandardError
      def initialize
        super("bitFlyer API response body exceeds #{MAX_RESPONSE_BODY_BYTES} bytes")
      end
    end

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

      def inspect = "#<#{self.class}>"

      def get(path, params = {})
        query = URI.encode_www_form(params.compact)
        full_path = query.empty? ? path : "#{path}?#{query}"
        request = Net::HTTP::Get.new(full_path, default_headers)
        execute(request)
      end

      def post(path, body = {})
        request = Net::HTTP::Post.new(path, default_headers.merge('Content-Type' => 'application/json'))
        request.body = JSON.generate(body.compact)
        execute(request)
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
        status = response.code.to_i
        body = response.body
        raise ResponseError.new(status, body) unless (200...300).cover?(status)

        Response.new(parse_body(body))
      end

      def send_request(request)
        http = (@http ||= Net::HTTP.start(
          @uri.host.to_s, @uri.port, use_ssl: true, keep_alive_timeout: 10, max_retries: 0
        ))
        sign_request(request, request.path, request.body)
        request_with_retry(http, request)
      rescue StandardError
        close_session
        raise
      end

      def request_with_retry(http, request)
        # Each attempt buffers its own body, so a failed GET can restart safely.
        retry_get = request.method == 'GET'
        begin
          http.request(request) { |response| response.body = read_response_body(response) }
        rescue Net::OpenTimeout
          raise
        rescue Timeout::Error, IOError, Errno::ECONNRESET, Errno::ECONNABORTED,
               Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError
          raise unless retry_get

          retry_get = false
          retry
        end
      end

      def read_response_body(response)
        body = +''
        oversized = false
        result = response.read_body do |chunk|
          if body.bytesize + chunk.bytesize > MAX_RESPONSE_BODY_BYTES
            oversized = true
            close_session
            break
          end
          body << chunk
        end
        body unless result.nil?
      ensure
        # Net::HTTP may try to read the chunk terminator while unwinding.
        raise ResponseTooLargeError if oversized
      end

      def close_session
        http = @http
        @http = nil
        http&.finish
      end

      def parse_body(body)
        return if body.nil?

        JSON.parse(body)
      rescue JSON::ParserError
        body
      end
    end
  end
end
