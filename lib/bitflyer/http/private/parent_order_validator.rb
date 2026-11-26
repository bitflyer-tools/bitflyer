# frozen_string_literal: true

module Bitflyer
  module HTTP
    module Private
      class ParentOrderValidator
        PARENT_ORDER_CONDITION_COUNTS = { 'SIMPLE' => 1, 'IFD' => 2, 'OCO' => 2, 'IFDOCO' => 3 }.freeze
        PARENT_ORDER_REQUIRED_FIELDS = %w[product_code condition_type side size].freeze
        PARENT_ORDER_CONDITION_FIELDS = {
          'LIMIT' => %w[price].freeze,
          'STOP' => %w[trigger_price].freeze,
          'STOP_LIMIT' => %w[price trigger_price].freeze,
          'TRAIL' => %w[offset].freeze
        }.freeze
        private_constant :PARENT_ORDER_REQUIRED_FIELDS, :PARENT_ORDER_CONDITION_FIELDS
        private_constant :PARENT_ORDER_CONDITION_COUNTS

        def self.validate_parent_order_condition_count(order_method, count)
          expected_count = PARENT_ORDER_CONDITION_COUNTS[order_method]
          return if expected_count.nil? || count == expected_count

          raise ArgumentError, "#{order_method} requires exactly #{expected_count} in parameters (got #{count})"
        end

        def self.normalize_parent_order_condition(condition)
          raise ArgumentError, 'each parent order condition must be a hash' unless condition.is_a?(Hash)

          # @type var normalized: Hash[String, untyped]
          normalized = {}
          condition.each_with_object(normalized) do |(key, value), fields|
            field = key.to_s
            raise ArgumentError, "duplicate parent order condition key: #{field}" if fields.key?(field)

            fields[field] = value
          end
        end

        def self.validate_parent_order_condition(fields)
          condition_type = fields['condition_type'].to_s
          required = PARENT_ORDER_REQUIRED_FIELDS + PARENT_ORDER_CONDITION_FIELDS.fetch(condition_type, [])
          required.each do |field|
            raise ArgumentError, "#{field} is required in a parent order condition" if fields.fetch(field, nil).nil?
          end
          validate_order_numbers(fields)
          return unless condition_type == 'TRAIL'

          raise ArgumentError, 'offset must be a positive Integer' unless fields['offset'].positive?
        end

        def self.validate_order_numbers(fields)
          fields.each do |field, value|
            case field
            when :price, 'price', :size, 'size', :trigger_price, 'trigger_price'
              next if json_number?(value)

              raise ArgumentError, "#{field} must be an Integer or a finite Float"
            when :minute_to_expire, 'minute_to_expire', :offset, 'offset'
              raise ArgumentError, "#{field} must be an Integer" unless value.is_a?(Integer)
            end
          end
        end

        def self.json_number?(value)
          value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
        end
      end
    end
  end
end
