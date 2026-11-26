# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Public::Client do
  let(:client) { described_class.new }
  let(:connection) { instance_double(Bitflyer::HTTP::Connection) }
  let(:response) { double('Response', body: {}) }

  before do
    allow(Bitflyer::HTTP::Connection).to receive(:new).with(nil, nil).and_return(connection)
    allow(connection).to receive(:get).and_return(response)
  end

  describe '#markets' do
    it 'calls GET /v1/markets' do
      client.markets
      expect(connection).to have_received(:get).with('/v1/markets')
    end
  end

  describe '#board' do
    it 'calls GET /v1/board with default product_code' do
      client.board
      expect(connection).to have_received(:get).with('/v1/board', product_code: 'BTC_JPY')
    end

    it 'calls GET /v1/board with custom product_code' do
      client.board(product_code: 'ETH_JPY')
      expect(connection).to have_received(:get).with('/v1/board', product_code: 'ETH_JPY')
    end
  end

  describe '#ticker' do
    it 'calls GET /v1/ticker with default product_code' do
      client.ticker
      expect(connection).to have_received(:get).with('/v1/ticker', product_code: 'BTC_JPY')
    end
  end

  describe '#board_state' do
    it 'calls GET /v1/getboardstate with default product_code' do
      client.board_state
      expect(connection).to have_received(:get).with('/v1/getboardstate', product_code: 'BTC_JPY')
    end

    it 'calls GET /v1/getboardstate with custom product_code' do
      client.board_state(product_code: 'ETH_JPY')
      expect(connection).to have_received(:get).with('/v1/getboardstate', product_code: 'ETH_JPY')
    end
  end

  describe '#executions' do
    it 'calls GET /v1/executions with default params' do
      client.executions
      expect(connection).to have_received(:get).with('/v1/executions', product_code: 'BTC_JPY')
    end

    it 'passes optional parameters' do
      client.executions(product_code: 'ETH_JPY', count: 10, before: 100, after: 50)
      expect(connection).to have_received(:get).with(
        '/v1/executions',
        product_code: 'ETH_JPY', count: 10, before: 100, after: 50
      )
    end
  end

  describe '#each_execution' do
    def execution_page(*ids)
      Bitflyer::HTTP::Response.new(ids.map { |id| { 'id' => id } })
    end

    it 'fetches pages lazily using the lowest ID and preserves filters and response order' do
      filters = { product_code: 'ETH_JPY', count: 3, after: 10 }
      history = client.each_execution(**filters, before: 100)
      expect(connection).not_to have_received(:get)

      expect(connection).to receive(:get).with('/v1/executions', filters.merge(before: 100))
                                         .ordered.and_return(execution_page(95, 90, 92))
      expect(connection).to receive(:get).with('/v1/executions', filters.merge(before: 90))
                                         .ordered.and_return(execution_page(80))
      expect(connection).to receive(:get).with('/v1/executions', filters.merge(before: 80))
                                         .ordered.and_return(execution_page)

      expect(history.map { |execution| execution.fetch('id') }).to eq([95, 90, 92, 80])
    end

    it 'starts at the latest page and stops fetching when the caller has enough records' do
      expect(connection).to receive(:get).with('/v1/executions', { product_code: 'BTC_JPY' })
                                         .once.and_return(execution_page(95, 90))

      expect(client.each_execution.first).to eq('id' => 95)
    end

    it 'stops at the requested page budget' do
      expect(connection).to receive(:get).with('/v1/executions', { product_code: 'BTC_JPY' })
                                         .once.and_return(execution_page(95, 90))

      expect(client.each_execution(max_pages: 1).to_a.size).to eq(2)
    end

    it 'defaults to a budget of ten requests' do
      id = 100
      expect(connection).to receive(:get).exactly(10).times { execution_page(id -= 1) }

      expect(client.each_execution.to_a.size).to eq(10)
    end

    it 'returns no executions and makes no requests with a zero page budget' do
      expect(client.each_execution(max_pages: 0).to_a).to be_empty
      expect(connection).not_to have_received(:get)
    end

    it 'rejects invalid page budgets before making a request' do
      [-1, 1.5, nil].each do |budget|
        expect { client.each_execution(max_pages: budget) }.to raise_error(ArgumentError, /max_pages/)
      end
      expect(connection).not_to have_received(:get)
    end

    it 'stops before yielding a page whose cursor does not move backward' do
      expect(connection).to receive(:get).with('/v1/executions', { product_code: 'BTC_JPY' })
                                         .ordered.and_return(execution_page(95, 90))
      expect(connection).to receive(:get).with('/v1/executions', { product_code: 'BTC_JPY', before: 90 })
                                         .ordered.and_return(execution_page(95, 90))

      expect(client.each_execution.to_a).to eq([{ 'id' => 95 }, { 'id' => 90 }])
    end

    it 'propagates a request failure during iteration' do
      error = Bitflyer::HTTP::ResponseError.new(429, 'Rate limit exceeded')
      expect(connection).to receive(:get).and_raise(error)

      expect { client.each_execution.to_a }.to raise_error { |raised| expect(raised).to equal(error) }
    end
  end

  describe '#chats' do
    it 'formats a Time from_date as ISO 8601 with milliseconds' do
      frozen_time = Time.new(2025, 1, 10, 0, 0, 0, '+00:00')
      client.chats(from_date: frozen_time)
      expect(connection).to have_received(:get).with('/v1/getchats', from_date: '2025-01-10T00:00:00.000')
    end

    it 'passes a String from_date through unchanged' do
      client.chats(from_date: '2025-01-10T00:00:00.000')
      expect(connection).to have_received(:get).with('/v1/getchats', from_date: '2025-01-10T00:00:00.000')
    end
  end
end

describe 'Public health requests' do
  let(:client) { Bitflyer.http_public_client }

  describe 'GET /v1/gethealth' do
    let(:http) { instance_double(Net::HTTP) }
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: '{"status":"NORMAL"}') }

    before do
      allow(Net::HTTP).to receive(:start).and_return(http)
      allow(http).to receive(:request).and_return(http_response)
    end

    it 'calls GET /v1/gethealth' do
      client.health
      expect(http).to have_received(:request).with(have_attributes(method: 'GET', path: '/v1/gethealth'))
    end

    it 'calls GET /v1/gethealth with the requested product code' do
      client.health(product_code: 'ETH_JPY')
      expect(http).to have_received(:request).with(
        have_attributes(method: 'GET', path: '/v1/gethealth?product_code=ETH_JPY')
      )
    end

    it 'calls GET /v1/gethealth when product_code is explicitly nil' do
      client.health(product_code: nil)
      expect(http).to have_received(:request).with(have_attributes(method: 'GET', path: '/v1/gethealth'))
    end
  end

  describe 'GET /v1/getchats' do
    let(:http) { instance_double(Net::HTTP) }
    let(:http_response) { instance_double(Net::HTTPOK, code: '200', body: '[]') }

    before do
      allow(Net::HTTP).to receive(:start).and_return(http)
      allow(http).to receive(:request).and_return(http_response)
    end

    it 'sends an ISO 8601 formatted from_date query parameter' do
      frozen_time = Time.new(2025, 1, 10, 0, 0, 0, '+00:00')
      client.chats(from_date: frozen_time)
      expect(http).to have_received(:request).with(
        have_attributes(method: 'GET', path: '/v1/getchats?from_date=2025-01-10T00%3A00%3A00.000')
      )
    end
  end
end
