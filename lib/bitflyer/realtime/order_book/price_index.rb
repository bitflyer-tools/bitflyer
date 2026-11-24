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

        def before?(a, b)
          @descending ? a > b : a < b
        end

        def swap(i, j)
          vi = @heap.fetch(i)
          vj = @heap.fetch(j)
          @heap[i] = vj
          @heap[j] = vi
          @positions[vj] = i
          @positions[vi] = j
        end

        def sift_up(i)
          while i > 0
            parent = (i - 1) / 2
            break unless before?(@heap.fetch(i), @heap.fetch(parent))

            swap(i, parent)
            i = parent
          end
        end

        def sift_down(i)
          size = @heap.size
          loop do
            left = (2 * i) + 1
            right = (2 * i) + 2
            top = i
            top = left if left < size && before?(@heap.fetch(left), @heap.fetch(top))
            top = right if right < size && before?(@heap.fetch(right), @heap.fetch(top))
            break if top == i

            swap(i, top)
            i = top
          end
        end
      end
    end
  end
end
