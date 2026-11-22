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

          @top_of_book ||= TopOfBook.new(
            best_bid: @bids.each_value.max_by(&:price),
            best_ask: @asks.each_value.min_by(&:price)
          )
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
        @current = nil
        @top_of_book = nil
        @ready = false
      end

      def merge(message)
        @current = nil
        @top_of_book = nil
        merge_side(@bids, message.fetch('bids'))
        merge_side(@asks, message.fetch('asks'))
      end

      def merge_side(side, levels)
        levels.each do |level|
          price = level.fetch('price')
          size = level.fetch('size')
          next if price.zero?

          key = price.to_r
          size.zero? ? side.delete(key) : side[key] = Level.new(price: price, size: size)
        end
      end

      def sorted_levels(side)
        side.values.sort_by(&:price)
      end
    end
  end
end
