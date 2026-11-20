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
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: response_body) }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts|
        http = double('http')
        allow(http).to receive(:request).and_return(http_response)
        http
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'returns a Response with parsed JSON body' do
      result = connection.get('/v1/gethealth')
      expect(result.body).to eq({ 'status' => 'ok' })
    end

    context 'when the response body is invalid JSON' do
      let(:response_body) { '{"status":' }

      it 'returns the original response body' do
        expect(connection.get('/v1/gethealth').body).to eq(response_body)
      end
    end
  end

  describe '#post' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:response_body) { '{"child_order_acceptance_id":"123"}' }
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: response_body) }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts|
        http = double('http')
        allow(http).to receive(:request).and_return(http_response)
        http
      end
      allow(Time).to receive_message_chain(:now, :to_i).and_return(1_000_000)
    end

    it 'returns a Response with parsed JSON body' do
      result = connection.post('/v1/me/sendchildorder', product_code: 'BTC_JPY')
      expect(result.body).to eq({ 'child_order_acceptance_id' => '123' })
    end
  end

  describe 'endpoint responses' do
    let(:response) { double('HTTP response', code: status, body: body) }

    before do
      transport = instance_double(Net::HTTP, request: response)
      allow(Net::HTTP).to receive(:start).and_return(transport)
    end

    context 'when cancellation returns an empty 200 response' do
      let(:status) { '200' }
      let(:body) { '' }

      it 'returns an empty string' do
        expect(Bitflyer.http_private_client('key', 'secret').cancel_all_child_orders).to eq('')
      end
    end

    context 'when cancellation returns an empty 503 response' do
      let(:status) { '503' }
      let(:body) { '' }

      it 'raises an error with the status and empty body' do
        expect do
          Bitflyer.http_private_client('key', 'secret').cancel_all_child_orders
        end.to raise_error(Bitflyer::HTTP::ResponseError) { |error|
          expect(error).to have_attributes(status: 503, body: '')
        }
      end
    end

    context 'when cancellation returns 204 with no body' do
      let(:status) { '204' }
      let(:body) { nil }

      it 'returns nil' do
        expect(Bitflyer.http_private_client('key', 'secret').cancel_all_child_orders).to be_nil
      end
    end

    context 'when a GET endpoint returns an error with a JSON body' do
      let(:status) { '429' }
      let(:body) { '{"error":"Too many requests"}' }

      it 'raises the same error with the raw body' do
        expect do
          Bitflyer.http_public_client.health
        end.to raise_error(Bitflyer::HTTP::ResponseError) { |error|
          expect(error).to have_attributes(status: 429, body: body)
        }
      end
    end
  end

  describe 'public Crypto CFD funding requests' do
    let(:client) { Bitflyer.http_public_client }
    let(:transport) { instance_double(Net::HTTP) }

    before do
      allow(Net::HTTP).to receive(:start).and_return(transport)
    end

    def stub_funding_request(path, query, body)
      response = instance_double(Net::HTTPOK, code: '200', body: JSON.generate(body))
      expect(transport).to receive(:request) do |request|
        uri = URI.parse(request.path)
        expect(request.method).to eq('GET')
        expect(uri.path).to eq(path)
        expect(URI.decode_www_form(uri.query)).to match_array(query.to_a)
        expect(request.to_hash.keys.grep(/\Aaccess-/)).to be_empty
        response
      end
    end

    it 'returns the upcoming rate and settlement time' do
      body = { 'current_funding_rate' => -0.00375, 'next_funding_rate_settledate' => '2024-04-15T13:00:00' }
      stub_funding_request('/v1/getfundingrate', { 'product_code' => 'FX_BTC_JPY' }, body)

      expect(client.funding_rate(product_code: 'FX_BTC_JPY')).to eq(body)
    end

    it 'passes all history filters and preserves the response order and fields' do
      from = '2024-04-14T00:00:00'
      to = '2024-04-16T00:00:00'
      body = [
        { 'calculation_date' => '2024-04-15T05:00:00', 'settlement_date' => '2024-04-15T13:00:00', 'rate' => -0.00375 },
        { 'calculation_date' => '2024-04-14T21:00:00', 'settlement_date' => '2024-04-15T05:00:00', 'rate' => 0.00125 }
      ]
      query = { 'product_code' => 'FX_BTC_JPY', 'from' => from, 'to' => to, 'count' => '10' }
      stub_funding_request('/v1/getfundingratehistory', query, body)

      expect(client.funding_rate_history(product_code: 'FX_BTC_JPY', from: from, to: to, count: 10)).to eq(body)
    end

    it 'omits unset history filters and returns an empty history as an array' do
      stub_funding_request('/v1/getfundingratehistory', { 'product_code' => 'FX_BTC_JPY' }, [])

      expect(client.funding_rate_history(product_code: 'FX_BTC_JPY', from: nil, count: nil)).to eq([])
    end
  end

  describe 'sign_request (via get)' do
    let(:connection) { described_class.new('test_key', 'test_secret') }
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: '{}') }
    let(:captured_request) { nil }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts|
        http = double('http')
        allow(http).to receive(:request) do |req|
          @captured_request = req
          http_response
        end
        http
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

    it 'sends and signs the absolute trading commission request target' do
      client = Bitflyer.http_private_client('test_key', 'test_secret')
      client.trading_commission(product_code: 'ETH_JPY')

      expected_path = '/v1/me/gettradingcommission?product_code=ETH_JPY'
      expected_sign = OpenSSL::HMAC.hexdigest('sha256', 'test_secret', "1000000GET#{expected_path}")
      expect(@captured_request).to have_attributes(method: 'GET', path: expected_path)
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
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: '{}') }

    before do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts|
        http = double('http')
        allow(http).to receive(:request) do |req|
          @captured_request = req
          http_response
        end
        http
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
