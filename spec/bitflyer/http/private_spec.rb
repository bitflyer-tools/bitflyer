# frozen_string_literal: true

require 'spec_helper'

describe Bitflyer::HTTP::Private::Client do
  let(:client) { described_class.new('test_key', 'test_secret') }
  let(:http) { instance_double(Net::HTTP) }
  let(:response) { instance_double(Net::HTTPOK, body: '[{"id":75}]') }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http)
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
