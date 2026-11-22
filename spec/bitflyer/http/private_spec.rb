# frozen_string_literal: true

require 'spec_helper'
require 'bigdecimal'

describe Bitflyer::HTTP::Private::Client do
  describe '#send_child_order' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:order) { { child_order_type: 'MARKET', side: 'BUY', size: 0.1 } }

    %i[child_order_type side size].each do |field|
      it "rejects an omitted #{field} before making an HTTP request" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.send_child_order(**order.reject { |key, _| key == field }) }
          .to raise_error(ArgumentError, "missing keyword: :#{field}")
      end

      it "rejects a nil #{field} before making an HTTP request" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.send_child_order(**order.merge(field => nil)) }
          .to raise_error(ArgumentError, "#{field} is required")
      end
    end

    [{}, { price: nil }].each do |price_option|
      it "rejects a limit order with #{price_option.empty? ? 'an omitted' : 'a nil'} price before making an HTTP request" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.send_child_order(**order.merge(child_order_type: 'LIMIT', **price_option)) }
          .to raise_error(ArgumentError, 'price is required for LIMIT orders')
      end
    end

    {
      'MARKET' => {},
      'LIMIT' => { price: 30_000 }
    }.each do |order_type, price_option|
      it "posts a complete #{order_type} order" do
        http = instance_double(Net::HTTP)
        response = instance_double(Net::HTTPOK, code: '200', body: '{"child_order_acceptance_id":"123"}')
        allow(Net::HTTP).to receive(:start).and_return(http)
        params = order.merge(child_order_type: order_type, **price_option)
        expect(http).to receive(:request) do |request|
          expect(request).to be_an_instance_of(Net::HTTP::Post)
          expect(request.path).to eq('/v1/me/sendchildorder')
          expect(JSON.parse(request.body)).to eq(
            params.merge(product_code: 'BTC_JPY', time_in_force: 'GTC').transform_keys(&:to_s)
          )
          response
        end

        expect(client.send_child_order(**params)).to eq('child_order_acceptance_id' => '123')
      end
    end
  end

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

  describe '#parent_orders' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:http) { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPOK, code: '200', body: '[{"id":75,"parent_order_state":"ACTIVE"}]') }

    before do
      allow(Net::HTTP).to receive(:start).and_return(http)
      allow(http).to receive(:request).and_return(response)
      allow(Time).to receive(:now).and_return(Time.at(1_000_000))
    end

    it 'requests the default product without optional filters' do
      client.parent_orders

      expect(http).to have_received(:request).with(
        an_instance_of(Net::HTTP::Get).and(have_attributes(path: '/v1/me/getparentorders?product_code=BTC_JPY'))
      )
    end

    it 'sends the product, state, and pagination filters and returns the parsed orders' do
      orders = client.parent_orders(product_code: 'ETH_JPY', count: 10, before: 100, after: 50,
                                    parent_order_state: 'ACTIVE')

      expect(orders).to eq([{ 'id' => 75, 'parent_order_state' => 'ACTIVE' }])
      expect(http).to have_received(:request) do |request|
        uri = URI.parse(request.path)
        expect(request).to be_an_instance_of(Net::HTTP::Get)
        expect(uri.path).to eq('/v1/me/getparentorders')
        expect(URI.decode_www_form(uri.query).to_h).to eq(
          'product_code' => 'ETH_JPY', 'count' => '10', 'before' => '100', 'after' => '50',
          'parent_order_state' => 'ACTIVE'
        )
      end
    end

    context 'when the API rejects the request' do
      let(:body) { '{"error":"Unauthorized"}' }
      let(:response) { instance_double(Net::HTTPUnauthorized, code: '401', body: body) }

      it 'raises a response error with the status and raw body' do
        expect do
          client.parent_orders
        end.to raise_error(Bitflyer::HTTP::ResponseError, 'bitFlyer API returned HTTP 401') { |error|
          expect(error).to have_attributes(status: 401, body: body)
        }
      end
    end
  end

  describe 'single-order requests' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:connection) { instance_double(Bitflyer::HTTP::Connection) }

    before do
      allow(Bitflyer::HTTP::Connection).to receive(:new).with('test_key', 'test_secret').and_return(connection)
    end

    {
      cancel_child_order: [:post, '/v1/me/cancelchildorder', :child_order_id, :child_order_acceptance_id],
      cancel_parent_order: [:post, '/v1/me/cancelparentorder', :parent_order_id, :parent_order_acceptance_id],
      parent_order: [:get, '/v1/me/getparentorder', :parent_order_id, :parent_order_acceptance_id]
    }.each do |method, (verb, path, order_id, acceptance_id)|
      describe "##{method}" do
        it 'rejects missing identifiers before dispatch' do
          expect(connection).not_to receive(verb)
          expect { client.public_send(method) }.to raise_error(ArgumentError, /exactly one/)
          expect { client.public_send(method, order_id => nil, acceptance_id => nil) }
            .to raise_error(ArgumentError, /exactly one/)
        end

        it 'rejects two identifiers before dispatch' do
          expect(connection).not_to receive(verb)
          expect { client.public_send(method, order_id => 'order-id', acceptance_id => 'acceptance-id') }
            .to raise_error(ArgumentError, /exactly one/)
        end

        [[order_id, acceptance_id], [acceptance_id, order_id]].each do |identifier, other_identifier|
          it "forwards only #{identifier} when supplied" do
            parameters = { identifier => 'identifier' }
            parameters[:product_code] = 'BTC_JPY' if verb == :post
            expect(connection).to receive(verb).with(path, parameters).twice
                                               .and_return(Bitflyer::HTTP::Response.new({}))

            expect(client.public_send(method, identifier => 'identifier')).to eq({})
            expect(client.public_send(method, identifier => 'identifier', other_identifier => nil)).to eq({})
          end
        end
      end
    end
  end

  describe '#withdraw' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:fields) { { bank_account_id: 1234, amount: 12_000 } }
    let(:http) { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPOK, code: '200', body: '{"message_id":"withdrawal-id"}') }

    %i[bank_account_id amount].each do |field|
      it "rejects a missing #{field} before posting" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.withdraw(**fields.except(field)) }.to raise_error(ArgumentError, /missing keyword: :#{field}/)
      end
    end

    %i[bank_account_id amount currency_code].each do |field|
      it "rejects a nil #{field} before posting" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.withdraw(**fields.merge(field => nil)) }.to raise_error(ArgumentError, "#{field} is required")
      end
    end

    [BigDecimal('12000'), Rational(12_000, 1), Complex(12_000, 0), '12000',
     Float::INFINITY, -Float::INFINITY, Float::NAN].each do |amount|
      it "rejects amount #{amount.inspect} before making an HTTP request" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.withdraw(**fields.merge(amount: amount)) }
          .to raise_error(ArgumentError, 'amount must be an Integer or a finite Float')
      end
    end

    [12_000, 12_000.5].each do |amount|
      it "sends #{amount.inspect} as a JSON number with the default currency" do
        allow(Net::HTTP).to receive(:start).and_return(http)
        expect(http).to receive(:request) do |request|
          expect(request).to be_a(Net::HTTP::Post)
          expect(request.path).to eq('/v1/me/withdraw')
          expect(JSON.parse(request.body)).to match(
            'currency_code' => 'JPY', 'bank_account_id' => 1234, 'amount' => eql(amount)
          )
          response
        end

        expect(client.withdraw(**fields.merge(amount: amount))).to eq('message_id' => 'withdrawal-id')
      end
    end

    it 'includes the supplied two-factor authentication code' do
      allow(Net::HTTP).to receive(:start).and_return(http)
      expect(http).to receive(:request) do |request|
        expect(JSON.parse(request.body)).to include('code' => '012345')
        response
      end

      client.withdraw(**fields, code: '012345')
    end
  end

  describe '#send_child_order' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }

    it 'sends integer and floating-point order fields as JSON numbers' do
      http = instance_double(Net::HTTP)
      response = instance_double(Net::HTTPOK, code: '200', body: '{"child_order_acceptance_id":"123"}')
      allow(Net::HTTP).to receive(:start).and_return(http)
      expect(http).to receive(:request) do |request|
        expect(request.path).to eq('/v1/me/sendchildorder')
        expect(JSON.parse(request.body)).to include(
          'price' => be_kind_of(Integer).and(eq(30_000)),
          'size' => be_kind_of(Float).and(eq(0.01)),
          'minute_to_expire' => be_kind_of(Integer).and(eq(60))
        )
        response
      end

      client.send_child_order(child_order_type: 'LIMIT', side: 'BUY', price: 30_000, size: 0.01, minute_to_expire: 60)
    end

    it 'rejects a fractional expiration before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.send_child_order(child_order_type: 'MARKET', side: 'BUY', size: 1, minute_to_expire: 1.5) }
        .to raise_error(ArgumentError, 'minute_to_expire must be an Integer')
    end

    [BigDecimal('0.01'), Rational(1, 100), '0.01', Float::INFINITY, Float::NAN].each do |size|
      it "rejects size #{size.inspect} before making an HTTP request" do
        expect(Net::HTTP).not_to receive(:start)
        expect { client.send_child_order(child_order_type: 'MARKET', side: 'BUY', size: size) }
          .to raise_error(ArgumentError, 'size must be an Integer or a finite Float')
      end
    end
  end

  describe '#send_parent_order' do
    let(:client) { Bitflyer.http_private_client('test_key', 'test_secret') }
    let(:condition) { { product_code: 'BTC_JPY', condition_type: 'MARKET', side: 'BUY', size: 1 } }

    it 'rejects a missing parameters keyword before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.send_parent_order }.to raise_error(ArgumentError, /missing keyword: :parameters/)
    end

    it 'rejects a hash before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      expect { client.send_parent_order(parameters: condition) }.to raise_error(ArgumentError, 'parameters must be an array')
    end

    it 'rejects a BigDecimal quantity in a string-keyed condition before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      parameters = [condition.transform_keys(&:to_s).merge('size' => BigDecimal('0.01'))]
      expect { client.send_parent_order(parameters: parameters) }
        .to raise_error(ArgumentError, 'size must be an Integer or a finite Float')
    end

    {
      'MARKET' => {},
      'LIMIT' => { price: 30_000 },
      'STOP' => { trigger_price: 29_000 },
      'STOP_LIMIT' => { price: 28_800, trigger_price: 29_000 },
      'TRAIL' => { offset: 100 }
    }.each do |type, extra_fields|
      required_fields = type == 'MARKET' ? %i[product_code condition_type side size] : extra_fields.keys
      required_fields.each do |field|
        it "rejects a #{type} condition missing #{field} before making an HTTP request" do
          expect(Net::HTTP).not_to receive(:start)
          incomplete = condition.merge(condition_type: type, **extra_fields).reject { |key, _| key == field }

          expect { client.send_parent_order(parameters: [condition, incomplete]) }
            .to raise_error(ArgumentError, "#{field} is required in a parent order condition")
        end
      end
    end

    it 'rejects a nil required field in a string-keyed condition before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)
      incomplete = condition.transform_keys(&:to_s).merge('condition_type' => 'LIMIT', 'price' => nil)

      expect { client.send_parent_order(parameters: [incomplete]) }
        .to raise_error(ArgumentError, 'price is required in a parent order condition')
    end

    it 'rejects a non-hash condition before making an HTTP request' do
      expect(Net::HTTP).not_to receive(:start)

      expect { client.send_parent_order(parameters: [nil]) }
        .to raise_error(ArgumentError, 'each parent order condition must be a hash')
    end

    it 'serializes symbol-keyed and string-keyed order conditions as a JSON array' do
      http = instance_double(Net::HTTP)
      response = instance_double(Net::HTTPOK, code: '200', body: '{"parent_order_acceptance_id":"123"}')
      stop_limit = condition.merge(condition_type: 'STOP_LIMIT', price: 28_800, trigger_price: 29_000)
      trail = condition.transform_keys(&:to_s).merge('condition_type' => 'TRAIL', 'offset' => 100)
      allow(Net::HTTP).to receive(:start).and_return(http)
      expect(http).to receive(:request) do |request|
        expect(request.path).to eq('/v1/me/sendparentorder')
        expect(JSON.parse(request.body)).to eq(
          'order_method' => 'OCO',
          'time_in_force' => 'GTC',
          'parameters' => [stop_limit.transform_keys(&:to_s), trail]
        )
        response
      end

      expect(client.send_parent_order(parameters: [stop_limit, trail], order_method: 'OCO'))
        .to eq('parent_order_acceptance_id' => '123')
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

    it 'filters withdrawals by message ID' do
      client.withdrawals(message_id: 'example')
      expect(http).to have_received(:request).with(
        an_instance_of(Net::HTTP::Get).and(have_attributes(path: '/v1/me/getwithdrawals?message_id=example'))
      )
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
