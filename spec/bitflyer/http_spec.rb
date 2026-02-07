# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Connection do
  describe '#initialize' do
    it 'stores the base URI' do
      connection = described_class.new(nil, nil)
      uri = connection.instance_variable_get(:@uri)
      expect(uri.to_s).to eq('https://api.bitflyer.jp')
    end
  end

  describe '#get' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:response_body) { '{"status":"ok"}' }
    let(:http_response) { instance_double(Net::HTTPOK, body: response_body) }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
        http = double('http')
        allow(http).to receive(:request).and_return(http_response)
        block.call(http)
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'returns a Response with parsed JSON body' do
      result = connection.get('/v1/gethealth')
      expect(result.body).to eq({ 'status' => 'ok' })
    end
  end

  describe '#post' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:response_body) { '{"child_order_acceptance_id":"123"}' }
    let(:http_response) { instance_double(Net::HTTPOK, body: response_body) }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
        http = double('http')
        allow(http).to receive(:request).and_return(http_response)
        block.call(http)
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'returns a Response with parsed JSON body' do
      result = connection.post('/v1/me/sendchildorder', product_code: 'BTC_JPY')
      expect(result.body).to eq({ 'child_order_acceptance_id' => '123' })
    end
  end

  describe 'sign_request (via get)' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:http_response) { instance_double(Net::HTTPOK, body: '{}') }
    let(:captured_request) { nil }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
        http = double('http')
        allow(http).to receive(:request) do |req|
          @captured_request = req
          http_response
        end
        block.call(http)
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'adds ACCESS-KEY header' do
      connection.get('/v1/me/getbalance')
      expect(@captured_request['ACCESS-KEY']).to eq('test_key')
    end

    it 'adds ACCESS-TIMESTAMP header' do
      connection.get('/v1/me/getbalance')
      expect(@captured_request['ACCESS-TIMESTAMP']).to eq('1000000')
    end

    it 'adds a valid HMAC-SHA256 ACCESS-SIGN header' do
      connection.get('/v1/me/getbalance')

      expected_text = '1000000GET/v1/me/getbalance'
      expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
      expect(@captured_request['ACCESS-SIGN']).to eq(expected_sign)
    end

    it 'includes query string in signature' do
      connection.get('/v1/board', product_code: 'BTC_JPY')

      expected_text = '1000000GET/v1/board?product_code=BTC_JPY'
      expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
      expect(@captured_request['ACCESS-SIGN']).to eq(expected_sign)
    end

    it 'does not add auth headers without credentials' do
      connection_no_auth = described_class.new(nil, nil)
      connection_no_auth.get('/v1/gethealth')

      expect(@captured_request['ACCESS-KEY']).to be_nil
      expect(@captured_request['ACCESS-SIGN']).to be_nil
    end
  end

  describe 'sign_request (via post)' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:http_response) { instance_double(Net::HTTPOK, body: '{}') }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
        http = double('http')
        allow(http).to receive(:request) do |req|
          @captured_request = req
          http_response
        end
        block.call(http)
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'includes body in POST signature' do
      connection.post('/v1/me/sendchildorder', product_code: 'BTC_JPY')

      expected_text = '1000000POST/v1/me/sendchildorder{"product_code":"BTC_JPY"}'
      expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', expected_text)
      expect(@captured_request['ACCESS-SIGN']).to eq(expected_sign)
    end
  end
end
