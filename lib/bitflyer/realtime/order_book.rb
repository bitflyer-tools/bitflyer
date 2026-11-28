# frozen_string_literal: true

require_relative 'order_book/price_index'

module Bitflyer
  module Realtime
    class OrderBook
      # Caps retained levels per side so a feed sending small deltas at distinct prices, or a single
      # oversized snapshot, cannot grow client memory without bound.
      MAX_LEVELS_PER_SIDE = 5_000
      private_constant :MAX_LEVELS_PER_SIDE

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

      def initialize
        @lock = Mutex.new
        invalidate
      end

      def current
        @lock.synchronize do
          next unless @ready

          @current ||= View.new(
            bids: (@sorted_bids ||= sorted_levels(@bids).reverse.freeze),
            asks: (@sorted_asks ||= sorted_levels(@asks).freeze)
          )
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
        @bid_index = PriceIndex.new(descending: true)
        @ask_index = PriceIndex.new(descending: false)
        @best_bid = nil
        @best_ask = nil
        @sorted_bids = nil
        @sorted_asks = nil
        @current = nil
        @top_of_book = nil
        @ready = false
      end

      def merge(message)
        bids = message.fetch('bids')
        asks = message.fetch('asks')
        raise ArgumentError, 'Order book sides must be arrays' unless bids.is_a?(Array) && asks.is_a?(Array)

        @sorted_bids = @current = nil if merge_side(@bids, bids, @bid_index)
        @sorted_asks = @current = nil if merge_side(@asks, asks, @ask_index)
        best_bid = best_level(@bids, @bid_index)
        best_ask = best_level(@asks, @ask_index)
        @top_of_book = nil unless @best_bid.equal?(best_bid) && @best_ask.equal?(best_ask)
        @best_bid = best_bid
        @best_ask = best_ask
      end

      def merge_side(side, levels, index)
        levels.reduce(false) { |changed, level| !apply_level(side, index, level).nil? || changed }
      end

      def best_level(side, index)
        key = index.best
        key && side[key]
      end

      def apply_level(side, index, level)
        price = level.fetch('price')
        size = level.fetch('size')
        raise ArgumentError, 'Order book price and size must be finite non-negative numbers' unless
          valid_level_number?(price) && valid_level_number?(size)

        return if price.zero?

        key = price.to_r
        return remove_level(side, index, key) if size.zero?

        set_level(side, index, key, price, size)
      end

      def set_level(side, index, key, price, size)
        existing = side[key]
        return if existing && existing.price.eql?(price) && existing.size.eql?(size)

        raise ArgumentError, "Order book side exceeds #{MAX_LEVELS_PER_SIDE} levels" if new_level_over_limit?(side, key)

        index.add(key) unless existing
        side[key] = Level.new(price: price, size: size)
      end

      def remove_level(side, index, key)
        removed = side.delete(key)
        index.remove(key) if removed
        removed
      end

      def new_level_over_limit?(side, key)
        !side.key?(key) && side.size >= MAX_LEVELS_PER_SIDE
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
