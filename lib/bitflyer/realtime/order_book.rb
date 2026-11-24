# frozen_string_literal: true

module Bitflyer
  module Realtime
    class OrderBook
      class Level
        attr_reader :price, :size

        def initialize(price:, size:)
          @price = price
          @size = size
          freeze
        end
      end

      class TopOfBook
        attr_reader :best_bid, :best_ask

        def initialize(best_bid:, best_ask:)
          @best_bid = best_bid
          @best_ask = best_ask
          freeze
        end

        def spread
          bid = best_bid
          ask = best_ask
          return unless bid && ask

          # @type var ask_price: untyped
          ask_price = ask.price
          ask_price - bid.price
        end
      end

      class View < TopOfBook
        attr_reader :bids, :asks

        def initialize(bids:, asks:)
          @bids = bids.freeze
          @asks = asks.freeze
          super(best_bid: bids.first, best_ask: asks.first)
        end
      end

      # The read-only object returned to callers. It exposes no way to replace, update, or
      # invalidate the book it wraps; only the realtime client's internal update path can do that.
      class Handle
        def initialize(order_book)
          @order_book = order_book
        end

        def current
          @order_book.current
        end

        def top_of_book
          @order_book.top_of_book
        end

        def ready?
          @order_book.ready?
        end
      end

      def initialize
        @lock = Mutex.new
        invalidate
      end

      def current
        @lock.synchronize do
          next unless @ready

          @current ||= View.new(bids: sorted_levels(@bids).reverse, asks: sorted_levels(@asks))
        end
      end

      def top_of_book
        @lock.synchronize do
          next unless @ready

          @top_of_book ||= TopOfBook.new(best_bid: @best_bid, best_ask: @best_ask)
        end
      end

      def ready?
        @lock.synchronize { @ready }
      end

      # @api private
      def replace(message)
        @lock.synchronize do
          reset
          merge(message)
          @ready = true
        end
      end

      # @api private
      def update(message)
        @lock.synchronize do
          merge(message) if @ready
        rescue StandardError
          reset
          raise
        end
      end

      # @api private
      def invalidate
        @lock.synchronize { reset }
      end

      private

      def reset
        @bids = {}
        @asks = {}
        @best_bid = nil
        @best_ask = nil
        @current = nil
        @top_of_book = nil
        @ready = false
      end

      def merge(message)
        bids = message.fetch('bids')
        asks = message.fetch('asks')
        raise ArgumentError, 'Order book sides must be arrays' unless bids.is_a?(Array) && asks.is_a?(Array)

        @current = nil
        best_bid = merge_side(@bids, bids, @best_bid, descending: true)
        best_ask = merge_side(@asks, asks, @best_ask, descending: false)
        @top_of_book = nil unless @best_bid.equal?(best_bid) && @best_ask.equal?(best_ask)
        @best_bid = best_bid
        @best_ask = best_ask
      end

      def merge_side(side, levels, best, descending:)
        best_key = best ? best.price.to_r : nil
        levels.each do |level|
          key = apply_level(side, level)
          next unless key

          best_key = key if best_key.nil? || (descending ? key > best_key : key < best_key)
        end
        best_level(side, best_key, descending: descending)
      end

      def best_level(side, best_key, descending:)
        return unless best_key

        # A removed candidate needs a replacement only after the whole side has been updated.
        side[best_key] || side[descending ? side.each_key.max : side.each_key.min]
      end

      def apply_level(side, level)
        price = level.fetch('price')
        size = level.fetch('size')
        raise ArgumentError, 'Order book price and size must be finite non-negative numbers' unless
          valid_level_number?(price) && valid_level_number?(size)

        return if price.zero?

        key = price.to_r
        if size.zero?
          side.delete(key)
          return
        end

        side[key] = Level.new(price: price, size: size)
        key
      end

      def valid_level_number?(value)
        (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)) && value >= 0
      end

      def sorted_levels(side)
        side.values.sort_by(&:price)
      end
    end
  end
end
