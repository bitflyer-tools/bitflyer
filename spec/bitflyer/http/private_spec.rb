# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Private::Client do
  describe '#child_orders' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:connection) { instance_double(Bitflyer::HTTP::Connection) }

    before do
      allow(Bitflyer::HTTP::Connection).to receive(:new).with('test_key', 'test_secret').and_return(connection)
      allow(connection).to receive(:get).and_return(Bitflyer::HTTP::Response.new([]))
    end

    it 'passes the child order ID' do
      client.child_orders(child_order_id: 'JOR20150707-084555-022523')
      expect(connection).to have_received(:get).with(
        '/v1/me/getchildorders', { product_code: 'BTC_JPY', child_order_id: 'JOR20150707-084555-022523' }
      )
    end

    it 'passes the child order acceptance ID' do
      client.child_orders(child_order_acceptance_id: 'JRF20150707-084552-031927')
      expect(connection).to have_received(:get).with(
        '/v1/me/getchildorders', { product_code: 'BTC_JPY', child_order_acceptance_id: 'JRF20150707-084552-031927' }
      )
    end

    it 'preserves the default query without ID filters' do
      client.child_orders
      expect(connection).to have_received(:get).with('/v1/me/getchildorders', { product_code: 'BTC_JPY' })
    end
  end
end
