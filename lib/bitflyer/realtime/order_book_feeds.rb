# frozen_string_literal: true

require_relative 'order_book'

module Bitflyer
  module Realtime
    class OrderBookFeeds
      def initialize
        @books = {}
        @feeds = {}
      end

      def channels = @feeds.keys
      def include?(channel) = @feeds.key?(channel)
      def invalidate = @books.each_value(&:invalidate)

      def register(product_code)
        delta = :"lightning_board_#{product_code}"
        snapshot = :"lightning_board_snapshot_#{product_code}"
        book = @books[product_code] ||= register_order_book(delta, snapshot)
        [book, delta, snapshot]
      end

      def route(channel, messages)
        feed = @feeds[channel]
        return unless feed

        handler, delta_channel = feed
        return unless yield(delta_channel)

        messages.each do |message|
          handler.call(message)
        rescue StandardError => e
          puts e
          puts e.backtrace&.join("\n")
        end
      end

      private

      def register_order_book(delta_channel, snapshot_channel)
        book = OrderBook.new
        @feeds[delta_channel] = [book.method(:update), delta_channel]
        @feeds[snapshot_channel] = [book.method(:replace), delta_channel]
        book
      end
    end
  end
end
