# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Private::Client do
  describe '#each_execution' do
    it 'yields fills to a block and forwards order filters on every page' do
      connection = instance_double(Bitflyer::HTTP::Connection)
      allow(Bitflyer::HTTP::Connection).to receive(:new).with('test_key', 'test_secret').and_return(connection)
      client = Bitflyer.http_private_client('test_key', 'test_secret')
      filters = {
        product_code: 'ETH_JPY', count: 2, after: 20,
        child_order_id: 'order-id', child_order_acceptance_id: 'acceptance-id'
      }
      fill = { 'id' => 40 }
      expect(connection).to receive(:get).with('/v1/me/getexecutions', filters.merge(before: 50))
                                         .ordered.and_return(Bitflyer::HTTP::Response.new([fill]))
      expect(connection).to receive(:get).with('/v1/me/getexecutions', filters.merge(before: 40))
                                         .ordered.and_return(Bitflyer::HTTP::Response.new([]))

      fills = []
      client.each_execution(**filters, before: 50) { |execution| fills << execution }

      expect(fills).to eq([fill])
    end
  end

  describe '#send_parent_order' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:condition) { { product_code: 'BTC_JPY', condition_type: 'MARKET', side: 'BUY', size: 0.1 } }

    it 'rejects a missing parameters keyword before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.send_parent_order }.to raise_error(ArgumentError, /missing keyword: :parameters/)
    end

    it 'rejects a hash before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.send_parent_order(parameters: condition) }.to raise_error(ArgumentError, 'parameters must be an array')
    end

    it 'serializes the order conditions as a JSON array' do
      http = instance_double(Net::HTTP)
      response = instance_double(Net::HTTPOK, code: '200', body: '{"parent_order_acceptance_id":"123"}')
      allow(Net::HTTP).to receive(:start).and_yield(http)
      expect(http).to receive(:request) do |request|
        expect(request.path).to eq('/v1/me/sendparentorder')
        expect(JSON.parse(request.body)).to eq(
          'time_in_force' => 'GTC',
          'parameters' => [condition.transform_keys(&:to_s)]
        )
        response
      end

      expect(client.send_parent_order(parameters: [condition])).to eq('parent_order_acceptance_id' => '123')
    end
  end
end
