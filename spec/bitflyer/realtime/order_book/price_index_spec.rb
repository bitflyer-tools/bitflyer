# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::OrderBook::PriceIndex do
  subject(:index) { described_class.new(descending: descending) }

  shared_examples 'a price index' do
    it 'has no best key when empty' do
      expect(index.best).to be_nil
    end

    it 'does nothing when removing from an empty index' do
      expect { index.remove(10) }.not_to raise_error
      expect(index.best).to be_nil
    end

    it 'does nothing when removing a key that was never added' do
      index.add(10)
      index.remove(99)
      expect(index.best).to eq(10)
    end

    it 'ignores adding a key that is already tracked' do
      index.add(10)
      index.add(10)
      index.remove(10)
      expect(index.best).to be_nil
    end

    it 'removes the only key directly without needing to rebalance' do
      index.add(10)
      index.remove(10)
      expect(index.best).to be_nil
    end

    it 'keeps the heap invariant while building and draining a deeper heap' do
      keys = [50, 10, 90, 30, 70, 20, 80, 40, 60, 100, 5, 95, 15, 85, 25]
      present = []

      keys.each do |key|
        index.add(key)
        present << key
        expect(index.best).to eq(best_of(present))
      end

      [60, 10, 80, 50, 100].each do |key|
        present.delete(key)
        index.remove(key)
        expect(index.best).to eq(best_of(present))
      end

      until present.empty?
        key = present.shift
        index.remove(key)
        expect(index.best).to eq(best_of(present))
      end
    end
  end

  context 'when ascending (asks)' do
    let(:descending) { false }

    def best_of(present)
      present.min
    end

    include_examples 'a price index'

    it 'tracks the lowest key as keys are added in any order' do
      [30, 10, 20].each { |key| index.add(key) }
      expect(index.best).to eq(10)
    end

    it 'moves to the next lowest key after the best key is removed' do
      [30, 10, 20].each { |key| index.add(key) }
      index.remove(10)
      expect(index.best).to eq(20)
      index.remove(20)
      expect(index.best).to eq(30)
      index.remove(30)
      expect(index.best).to be_nil
    end

    it 'keeps the best key unchanged after removing a non-best key' do
      [30, 10, 20].each { |key| index.add(key) }
      index.remove(20)
      expect(index.best).to eq(10)
    end
  end

  context 'when descending (bids)' do
    let(:descending) { true }

    def best_of(present)
      present.max
    end

    include_examples 'a price index'

    it 'tracks the highest key as keys are added in any order' do
      [10, 30, 20].each { |key| index.add(key) }
      expect(index.best).to eq(30)
    end

    it 'moves to the next highest key after the best key is removed' do
      [10, 30, 20].each { |key| index.add(key) }
      index.remove(30)
      expect(index.best).to eq(20)
      index.remove(20)
      expect(index.best).to eq(10)
      index.remove(10)
      expect(index.best).to be_nil
    end

    it 'keeps the best key unchanged after removing a non-best key' do
      [10, 30, 20].each { |key| index.add(key) }
      index.remove(20)
      expect(index.best).to eq(30)
    end
  end
end
