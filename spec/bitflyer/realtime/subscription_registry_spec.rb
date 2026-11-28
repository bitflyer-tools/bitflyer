# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::SubscriptionRegistry do
  subject(:registry) { described_class.new(->(_message) {}) }

  let(:transport) { instance_double(Bitflyer::Realtime::Transport, send: true) }

  before do
    @now = 100_000
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC, :millisecond) { @now }
  end

  it 'keeps a token through callback replacement and session reset, and revokes it on unsubscribe' do
    first = ->(_message) {}
    second = ->(_message) {}
    registry.lock.synchronize do
      registry.register(:ticker, first)
      token = registry.token(:ticker)
      snapshot = registry.callbacks
      registry.register(:ticker, second)
      registry.reset

      expect(snapshot).to be_frozen
      expect(snapshot[:ticker]).to equal(first)
      expect(registry.callback(:ticker, token)).to equal(second)
      expect(registry.unregister?(:ticker)).to be(true)
      registry.register(:ticker, first)
      expect(registry.callback(:ticker, token)).to be_nil
    end
  end

  it 'ignores a queued acknowledgment and expires setup at the deadline' do
    registry.lock.synchronize do
      registry.setup([:ticker], transport)
      expect(registry.acknowledge(1, '[null]')).to be_nil
    end
    registry.flush

    @now += 10_000
    registry.lock.synchronize do
      expect(registry.acknowledge(1, '[null]')).to eq(:expired)
      expect(registry).not_to be_setup_acknowledged
      expect(registry).not_to be_acknowledged(:ticker)
      expect(registry.acknowledge(1, '[null]')).to be_nil
    end
  end

  it 'starts the runtime deadline at dispatch and removes canceled requests before they are sent' do
    registry.lock.synchronize do
      registry.setup([], transport)
      registry.queue_subscription(:canceled, transport)
      registry.cancel_subscription(:canceled, transport, true)
      registry.queue_subscription(:ticker, transport)
      @now += 20_000
      expect(registry.expire_runtime_subscriptions).to be_empty
    end
    registry.flush

    expect(transport).to have_received(:send).with('422["subscribe","ticker"]').once
    expect(transport).to have_received(:send).once

    registry.lock.synchronize do
      @now += 9_999
      expect(registry.expire_runtime_subscriptions).to be_empty
      @now += 1
      expect(registry.expire_runtime_subscriptions).to eq([:ticker])
      expect(registry.acknowledge(2, '[null]')).to be_nil
      expect(registry).to be_setup_acknowledged
    end
  end
end
