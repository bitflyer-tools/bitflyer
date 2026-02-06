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

  describe '#health' do
    it 'calls GET /v1/gethealth' do
      client.health
      expect(connection).to have_received(:get).with('/v1/gethealth')
    end
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

  describe '#chats' do
    it 'calls GET /v1/getchats with from_date' do
      frozen_time = Time.new(2025, 1, 10, 0, 0, 0, '+00:00')
      client.chats(from_date: frozen_time)
      expect(connection).to have_received(:get).with('/v1/getchats', from_date: frozen_time)
    end
  end
end
