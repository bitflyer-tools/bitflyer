# frozen_string_literal: true

module Bitflyer
  module Realtime
    class OrderBook
      # Tracks the best (highest bid / lowest ask) key for a side with a binary heap kept in
      # lockstep with that side's Hash, so the best key is always the heap root instead of
      # something found by scanning every remaining key.
      class PriceIndex
        def initialize(descending:)
          @descending = descending
          @heap = []
          @positions = {}
        end

        def best
          @heap.first
        end

        def add(key)
          return if @positions.key?(key)

          @heap << key
          i = @heap.size - 1
          @positions[key] = i
          sift_up(i)
        end

        def remove(key)
          i = @positions.delete(key)
          return unless i

          moved = @heap.pop
          return unless moved
          return if i == @heap.size

          @heap[i] = moved
          @positions[moved] = i
          sift_down(i)
          sift_up(i)
        end

        private

        def before?(lhs, rhs)
          @descending ? lhs > rhs : lhs < rhs
        end

        def swap(pos_a, pos_b)
          val_a = @heap.fetch(pos_a)
          val_b = @heap.fetch(pos_b)
          @heap[pos_a] = val_b
          @heap[pos_b] = val_a
          @positions[val_b] = pos_a
          @positions[val_a] = pos_b
        end

        def sift_up(idx)
          while idx.positive?
            parent = (idx - 1) / 2
            break unless before?(@heap.fetch(idx), @heap.fetch(parent))

            swap(idx, parent)
            idx = parent
          end
        end

        def sift_down(idx)
          size = @heap.size
          loop do
            left = (2 * idx) + 1
            right = (2 * idx) + 2
            top = idx
            top = left if left < size && before?(@heap.fetch(left), @heap.fetch(top))
            top = right if right < size && before?(@heap.fetch(right), @heap.fetch(top))
            break if top == idx

            swap(idx, top)
            idx = top
          end
        end
      end
    end
  end
end
