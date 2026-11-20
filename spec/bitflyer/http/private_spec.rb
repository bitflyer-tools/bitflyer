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

  describe '#withdraw' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:connection) { instance_double(Bitflyer::HTTP::Connection) }
    let(:fields) { { bank_account_id: 1234, amount: 12_000 } }

    before do
      allow(Bitflyer::HTTP::Connection).to receive(:new).with('test_key', 'test_secret').and_return(connection)
    end

    %i[bank_account_id amount].each do |field|
      it "rejects a missing #{field} before posting" do
        expect(connection).not_to receive(:post)
        expect { client.withdraw(**fields.except(field)) }.to raise_error(ArgumentError, /missing keyword: :#{field}/)
      end

      it "rejects a nil #{field} before posting" do
        expect(connection).not_to receive(:post)
        expect { client.withdraw(**fields.merge(field => nil)) }.to raise_error(ArgumentError, "#{field} is required")
      end
    end

    it 'posts the required fields with the default currency' do
      response = { 'message_id' => 'withdrawal-id' }
      expect(connection).to receive(:post).with('/v1/me/withdraw', fields.merge(currency_code: 'JPY'))
                                         .and_return(Bitflyer::HTTP::Response.new(response))

      expect(client.withdraw(**fields)).to eq(response)
    end

    it 'includes the supplied two-factor authentication code' do
      expect(connection).to receive(:post).with('/v1/me/withdraw', fields.merge(currency_code: 'JPY', code: '012345'))
                                         .and_return(Bitflyer::HTTP::Response.new({}))

      client.withdraw(**fields, code: '012345')
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
      allow(Net::HTTP).to receive(:start).and_return(http)
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

  describe 'history pagination' do
    let(:client) { described_class.new('test_key', 'test_secret') }
    let(:http) { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPOK, code: '200', body: '[{"id":75}]') }

    before do
      allow(Net::HTTP).to receive(:start).and_return(http)
      allow(http).to receive(:request).and_return(response)
    end

    {
      coin_ins: '/v1/me/getcoinins',
      coin_outs: '/v1/me/getcoinouts',
      deposits: '/v1/me/getdeposits',
      withdrawals: '/v1/me/getwithdrawals'
    }.each do |method, path|
      describe "##{method}" do
        it 'requests the default page without a query string' do
          expect(client.public_send(method)).to eq([{ 'id' => 75 }])
          expect(http).to have_received(:request).with(an_instance_of(Net::HTTP::Get).and(have_attributes(path: path)))
        end

        it 'sends all supplied pagination parameters' do
          client.public_send(method, count: 10, before: 100, after: 50)
          expect(http).to have_received(:request).with(
            have_attributes(path: "#{path}?count=10&before=100&after=50")
          )
        end

        it 'omits unspecified pagination parameters' do
          client.public_send(method, before: 100)
          expect(http).to have_received(:request).with(have_attributes(path: "#{path}?before=100"))
        end
      end
    end
  end
end
