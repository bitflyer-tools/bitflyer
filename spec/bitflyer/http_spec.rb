# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Connection do
  describe '#initialize' do
    it 'creates a Faraday connection' do
      connection = described_class.new(nil, nil)
      faraday = connection.instance_variable_get(:@connection)
      expect(faraday).to be_a(Faraday::Connection)
      expect(faraday.url_prefix.to_s).to eq('https://api.bitflyer.jp/')
    end
  end
end

describe Bitflyer::HTTP::Authentication do
  let(:app) { double('app') }
  let(:env) do
    {
      method: :get,
      url: URI.parse('https://api.bitflyer.jp/v1/me/getbalance'),
      request_headers: {},
      body: nil
    }
  end

  describe '#call' do
    context 'without credentials' do
      let(:middleware) { described_class.new(app, nil, nil) }

      it 'does not add auth headers' do
        allow(app).to receive(:call).and_return(env)
        middleware.call(env)

        expect(env[:request_headers]).not_to have_key('ACCESS-KEY')
        expect(env[:request_headers]).not_to have_key('ACCESS-SIGN')
      end

      it 'delegates to the app' do
        allow(app).to receive(:call).and_return(env)
        middleware.call(env)
        expect(app).to have_received(:call).with(env)
      end
    end

    context 'with credentials' do
      let(:middleware) { described_class.new(app, 'test_key', 'test_secret') }

      before do
        allow(app).to receive(:call).and_return(env)
        allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
      end

      it 'adds ACCESS-KEY header' do
        middleware.call(env)
        expect(env[:request_headers]['ACCESS-KEY']).to eq('test_key')
      end

      it 'adds ACCESS-TIMESTAMP header' do
        middleware.call(env)
        expect(env[:request_headers]['ACCESS-TIMESTAMP']).to eq('1000000')
      end

      it 'adds a valid HMAC-SHA256 ACCESS-SIGN header' do
        middleware.call(env)

        expected_text = '1000000GET/v1/me/getbalance'
        expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
        expect(env[:request_headers]['ACCESS-SIGN']).to eq(expected_sign)
      end

      it 'includes query string in signature' do
        env[:url] = URI.parse('https://api.bitflyer.jp/v1/board?product_code=BTC_JPY')
        middleware.call(env)

        expected_text = '1000000GET/v1/board?product_code=BTC_JPY'
        expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
        expect(env[:request_headers]['ACCESS-SIGN']).to eq(expected_sign)
      end

      it 'includes body in POST signature' do
        env[:method] = :post
        env[:body] = '{"product_code":"BTC_JPY"}'
        middleware.call(env)

        expected_text = '1000000POST/v1/me/getbalance{"product_code":"BTC_JPY"}'
        expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
        expect(env[:request_headers]['ACCESS-SIGN']).to eq(expected_sign)
      end
    end
  end
end
