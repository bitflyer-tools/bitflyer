# frozen_string_literal: true

module Bitflyer
  module HTTP
    module Private
      class Client # rubocop:disable Metrics/ClassLength
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

        def withdraw(currency_code: 'JPY', bank_account_id: nil, amount: nil, code: nil)
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
          product_code: 'BTC_JPY',
          child_order_type: nil,
          side: nil,
          price: nil,
          size: nil,
          minute_to_expire: nil,
          time_in_force: 'GTC'
        )
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
          body = {
            product_code: product_code,
            child_order_id: child_order_id,
            child_order_acceptance_id: child_order_acceptance_id
          }.delete_if { |_, v| v.nil? }
          @connection.post('/v1/me/cancelchildorder', body).body
        end

        def send_parent_order(parameters:, order_method: nil, minute_to_expire: nil, time_in_force: 'GTC')
          raise ArgumentError, 'parameters must be an array' unless parameters.is_a?(Array)

          body = {
            order_method: order_method,
            minute_to_expire: minute_to_expire,
            time_in_force: time_in_force,
            parameters: parameters
          }.delete_if { |_, v| v.nil? }
          validate_order_numbers(body)
          parameters.each { |condition| validate_order_numbers(condition) if condition.is_a?(Hash) }
          @connection.post('/v1/me/sendparentorder', body).body
        end

        def cancel_parent_order(product_code: 'BTC_JPY', parent_order_id: nil, parent_order_acceptance_id: nil)
          body = {
            product_code: product_code,
            parent_order_id: parent_order_id,
            parent_order_acceptance_id: parent_order_acceptance_id
          }.delete_if { |_, v| v.nil? }
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
          query = {
            parent_order_id: parent_order_id,
            parent_order_acceptance_id: parent_order_acceptance_id
          }.delete_if { |_, v| v.nil? }
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
