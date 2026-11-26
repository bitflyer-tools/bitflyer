# frozen_string_literal: true

require 'spec_helper'
require 'bigdecimal'

describe Bitflyer::HTTP::Private::ParentOrderValidator do
  describe '.validate_parent_order_condition_count' do
    { 'SIMPLE' => 1, 'IFD' => 2, 'OCO' => 2, 'IFDOCO' => 3 }.each do |order_method, count|
      it "accepts exactly #{count} conditions for #{order_method}" do
        expect { described_class.validate_parent_order_condition_count(order_method, count) }.not_to raise_error
      end

      [count - 1, count + 1].each do |invalid_count|
        it "rejects #{invalid_count} conditions for #{order_method}" do
          expect { described_class.validate_parent_order_condition_count(order_method, invalid_count) }
            .to raise_error(ArgumentError, "#{order_method} requires exactly #{count} in parameters (got #{invalid_count})")
        end
      end
    end

    it 'accepts any count for an order method without a fixed condition count' do
      expect { described_class.validate_parent_order_condition_count('UNKNOWN', 5) }.not_to raise_error
    end
  end

  describe '.normalize_parent_order_condition' do
    it 'rejects a non-hash condition' do
      expect { described_class.normalize_parent_order_condition(nil) }
        .to raise_error(ArgumentError, 'each parent order condition must be a hash')
    end

    it 'stringifies symbol keys' do
      expect(described_class.normalize_parent_order_condition(side: 'BUY'))
        .to eq('side' => 'BUY')
    end

    it 'merges mixed symbol and string keys that are unique after string conversion' do
      expect(described_class.normalize_parent_order_condition(side: 'BUY', 'size' => 1))
        .to eq('side' => 'BUY', 'size' => 1)
    end

    it 'rejects duplicate keys after string conversion' do
      expect { described_class.normalize_parent_order_condition(side: 'BUY', 'side' => 'SELL') }
        .to raise_error(ArgumentError, 'duplicate parent order condition key: side')
    end
  end

  describe '.validate_parent_order_condition' do
    let(:fields) { { 'product_code' => 'BTC_JPY', 'condition_type' => 'MARKET', 'side' => 'BUY', 'size' => 1 } }

    it 'accepts a condition with all required fields' do
      expect { described_class.validate_parent_order_condition(fields) }.not_to raise_error
    end

    %w[product_code condition_type side size].each do |field|
      it "rejects a condition missing #{field}" do
        expect { described_class.validate_parent_order_condition(fields.merge(field => nil)) }
          .to raise_error(ArgumentError, "#{field} is required in a parent order condition")
      end
    end

    {
      'LIMIT' => %w[price],
      'STOP' => %w[trigger_price],
      'STOP_LIMIT' => %w[price trigger_price],
      'TRAIL' => %w[offset]
    }.each do |condition_type, extra_fields|
      extra_fields.each do |field|
        it "requires #{field} for a #{condition_type} condition" do
          condition = fields.merge('condition_type' => condition_type, 'offset' => 1,
                                    'price' => 100, 'trigger_price' => 100).merge(field => nil)

          expect { described_class.validate_parent_order_condition(condition) }
            .to raise_error(ArgumentError, "#{field} is required in a parent order condition")
        end
      end
    end

    [0, -1].each do |offset|
      it "rejects a TRAIL offset of #{offset}" do
        condition = fields.merge('condition_type' => 'TRAIL', 'offset' => offset)

        expect { described_class.validate_parent_order_condition(condition) }
          .to raise_error(ArgumentError, 'offset must be a positive Integer')
      end
    end

    it 'rejects a non-numeric size' do
      expect { described_class.validate_parent_order_condition(fields.merge('size' => BigDecimal('0.01'))) }
        .to raise_error(ArgumentError, 'size must be an Integer or a finite Float')
    end
  end

  describe '.validate_order_numbers' do
    %i[price size trigger_price].each do |field|
      it "accepts an Integer #{field}" do
        expect { described_class.validate_order_numbers(field => 1) }.not_to raise_error
      end

      it "accepts a finite Float #{field}" do
        expect { described_class.validate_order_numbers(field => 1.5) }.not_to raise_error
      end

      [BigDecimal('1'), Rational(1, 1), Complex(1, 0), '1', Float::INFINITY, Float::NAN].each do |value|
        it "rejects #{value.inspect} for #{field}" do
          expect { described_class.validate_order_numbers(field => value) }
            .to raise_error(ArgumentError, "#{field} must be an Integer or a finite Float")
        end
      end
    end

    %i[minute_to_expire offset].each do |field|
      it "accepts an Integer #{field}" do
        expect { described_class.validate_order_numbers(field => 1) }.not_to raise_error
      end

      it "rejects a Float #{field}" do
        expect { described_class.validate_order_numbers(field => 1.5) }
          .to raise_error(ArgumentError, "#{field} must be an Integer")
      end
    end

    it 'ignores unrecognized fields' do
      expect { described_class.validate_order_numbers(product_code: 'BTC_JPY') }.not_to raise_error
    end
  end

  describe '.json_number?' do
    it 'accepts Integer and finite Float values' do
      expect(described_class.json_number?(1)).to be(true)
      expect(described_class.json_number?(1.5)).to be(true)
    end

    [BigDecimal('1'), Rational(1, 1), Complex(1, 0), '1', Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
      it "rejects #{value.inspect}" do
        expect(described_class.json_number?(value)).to be(false)
      end
    end
  end
end
