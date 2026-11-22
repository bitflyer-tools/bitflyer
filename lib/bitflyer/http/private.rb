# frozen_string_literal: true

module Bitflyer
  module HTTP
    module Private
      class Client # rubocop:disable Metrics/ClassLength
        PARENT_ORDER_REQUIRED_FIELDS = %w[product_code condition_type side size].freeze
        PARENT_ORDER_CONDITION_FIELDS = {
          'LIMIT' => %w[price].freeze,
          'STOP' => %w[trigger_price].freeze,
          'STOP_LIMIT' => %w[price trigger_price].freeze,
          'TRAIL' => %w[offset].freeze
        }.freeze
        private_constant :PARENT_ORDER_REQUIRED_FIELDS, :PARENT_ORDER_CONDITION_FIELDS

        def initialize(key, secret)
          @connection = Connection.new(key, secret)
        end

        def close
          @connection.close
        end

        def inspect = "#<#{self.class}>"

        def permissions
          @connection.get('/v1/me/getpermissions').body
        end

        def balance
          @connection.get('/v1/me/getbalance').body
        end

        def collateral
          @connection.get('/v1/me/getcollateral').body
        end

        def addresses
          @connection.get('/v1/me/getaddresses').body
        end

        def coin_ins(count: nil, before: nil, after: nil)
          @connection.get('/v1/me/getcoinins', count: count, before: before, after: after).body
        end

        def coin_outs(count: nil, before: nil, after: nil)
          @connection.get('/v1/me/getcoinouts', count: count, before: before, after: after).body
        end

        def bank_accounts
          @connection.get('/v1/me/getbankaccounts').body
        end

        def deposits(count: nil, before: nil, after: nil)
          @connection.get('/v1/me/getdeposits', count: count, before: before, after: after).body
        end

        def withdraw(bank_account_id:, amount:, currency_code: 'JPY', code: nil)
          raise ArgumentError, 'bank_account_id is required' if bank_account_id.nil?
          raise ArgumentError, 'amount is required' if amount.nil?
          raise ArgumentError, 'amount must be an Integer or a finite Float' unless json_number?(amount)

          body = {
            currency_code: currency_code,
            bank_account_id: bank_account_id,
            amount: amount,
            code: code
          }.delete_if { |_, v| v.nil? }
          @connection.post('/v1/me/withdraw', body).body
        end

        def withdrawals(count: nil, before: nil, after: nil, message_id: nil)
          @connection.get(
            '/v1/me/getwithdrawals', count: count, before: before, after: after, message_id: message_id
          ).body
        end

        def send_child_order(
          child_order_type:,
          side:,
          size:,
          product_code: 'BTC_JPY',
          price: nil,
          minute_to_expire: nil,
          time_in_force: 'GTC'
        )
          raise ArgumentError, 'child_order_type is required' if child_order_type.nil?
          raise ArgumentError, 'side is required' if side.nil?
          raise ArgumentError, 'size is required' if size.nil?
          raise ArgumentError, 'price is required for LIMIT orders' if child_order_type == 'LIMIT' && price.nil?

          body = {
            product_code: product_code,
            child_order_type: child_order_type,
            side: side,
            price: price,
            size: size,
            minute_to_expire: minute_to_expire,
            time_in_force: time_in_force
          }.delete_if { |_, v| v.nil? }
          validate_order_numbers(body)
          @connection.post('/v1/me/sendchildorder', body).body
        end

        def cancel_child_order(product_code: 'BTC_JPY', child_order_id: nil, child_order_acceptance_id: nil)
          identifier = order_identifier(
            child_order_id: child_order_id, child_order_acceptance_id: child_order_acceptance_id
          )
          body = { product_code: product_code }.compact.merge(identifier)
          @connection.post('/v1/me/cancelchildorder', body).body
        end

        def send_parent_order(parameters:, order_method: nil, minute_to_expire: nil, time_in_force: 'GTC')
          raise ArgumentError, 'parameters must be an array' unless parameters.is_a?(Array)

          body = {
            order_method: order_method,
            minute_to_expire: minute_to_expire,
            time_in_force: time_in_force
          }.delete_if { |_, v| v.nil? }
          validate_order_numbers(body)
          normalized_parameters = parameters.map do |condition|
            fields = normalize_parent_order_condition(condition)
            validate_parent_order_condition(fields)
            fields
          end
          @connection.post('/v1/me/sendparentorder', body.merge(parameters: normalized_parameters)).body
        end

        def cancel_parent_order(product_code: 'BTC_JPY', parent_order_id: nil, parent_order_acceptance_id: nil)
          identifier = order_identifier(
            parent_order_id: parent_order_id, parent_order_acceptance_id: parent_order_acceptance_id
          )
          body = { product_code: product_code }.compact.merge(identifier)
          @connection.post('/v1/me/cancelparentorder', body).body
        end

        def cancel_all_child_orders(product_code: 'BTC_JPY')
          @connection.post('/v1/me/cancelallchildorders', product_code: product_code).body
        end

        def child_orders( # rubocop:disable Metrics/ParameterLists
          product_code: 'BTC_JPY',
          count: nil,
          before: nil,
          after: nil,
          child_order_state: nil,
          parent_order_id: nil,
          child_order_id: nil,
          child_order_acceptance_id: nil
        )
          query = {
            product_code: product_code,
            count: count,
            before: before,
            after: after,
            child_order_state: child_order_state,
            parent_order_id: parent_order_id,
            child_order_id: child_order_id,
            child_order_acceptance_id: child_order_acceptance_id
          }.delete_if { |_, v| v.nil? }
          @connection.get('/v1/me/getchildorders', query).body
        end

        def parent_orders(product_code: 'BTC_JPY', count: nil, before: nil, after: nil, parent_order_state: nil)
          query = {
            product_code: product_code,
            count: count,
            before: before,
            after: after,
            parent_order_state: parent_order_state
          }.delete_if { |_, v| v.nil? }
          @connection.get('/v1/me/getparentorders', query).body
        end

        def parent_order(parent_order_id: nil, parent_order_acceptance_id: nil)
          query = order_identifier(
            parent_order_id: parent_order_id, parent_order_acceptance_id: parent_order_acceptance_id
          )
          @connection.get('/v1/me/getparentorder', query).body
        end

        def executions(
          product_code: 'BTC_JPY',
          count: nil,
          before: nil,
          after: nil,
          child_order_id: nil,
          child_order_acceptance_id: nil
        )
          query = {
            product_code: product_code,
            count: count,
            before: before,
            after: after,
            child_order_id: child_order_id,
            child_order_acceptance_id: child_order_acceptance_id
          }.delete_if { |_, v| v.nil? }
          @connection.get('/v1/me/getexecutions', query).body
        end

        def each_execution(
          product_code: 'BTC_JPY',
          count: nil,
          before: nil,
          after: nil,
          child_order_id: nil,
          child_order_acceptance_id: nil,
          max_pages: ExecutionHistory::DEFAULT_MAX_PAGES,
          &block
        )
          stream = ExecutionHistory.stream(before, max_pages) do |cursor|
            executions(
              product_code: product_code, count: count, before: cursor, after: after,
              child_order_id: child_order_id, child_order_acceptance_id: child_order_acceptance_id
            )
          end
          return stream unless block

          stream.each(&block)
          nil
        end

        def balance_history(currency_code: nil, count: nil, before: nil, after: nil)
          query = {
            currency_code: currency_code,
            count: count,
            before: before,
            after: after
          }.delete_if { |_, v| v.nil? }
          @connection.get('/v1/me/getbalancehistory', query).body
        end

        def positions(product_code: 'FX_BTC_JPY')
          @connection.get('/v1/me/getpositions', product_code: product_code).body
        end

        def trading_commission(product_code: 'BTC_JPY')
          @connection.get('/v1/me/gettradingcommission', product_code: product_code).body
        end

        private

        def order_identifier(**identifiers)
          supplied = identifiers.compact
          return supplied if supplied.size == 1

          raise ArgumentError, "Provide exactly one of #{identifiers.keys.join(' or ')}"
        end

        def normalize_parent_order_condition(condition)
          raise ArgumentError, 'each parent order condition must be a hash' unless condition.is_a?(Hash)

          # @type var normalized: Hash[String, untyped]
          normalized = {}
          condition.each_with_object(normalized) do |(key, value), fields|
            field = key.to_s
            raise ArgumentError, "duplicate parent order condition key: #{field}" if fields.key?(field)

            fields[field] = value
          end
        end

        def validate_parent_order_condition(fields)
          condition_type = fields['condition_type'].to_s
          required = PARENT_ORDER_REQUIRED_FIELDS + PARENT_ORDER_CONDITION_FIELDS.fetch(condition_type, [])
          required.each do |field|
            raise ArgumentError, "#{field} is required in a parent order condition" if fields.fetch(field, nil).nil?
          end
          validate_order_numbers(fields)
        end

        def validate_order_numbers(fields)
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

        def json_number?(value)
          value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
        end
      end
    end
  end
end
