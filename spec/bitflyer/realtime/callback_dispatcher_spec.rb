# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bitflyer::Realtime::CallbackDispatcher do
  subject(:dispatcher) do
    described_class.new(lock) { ->(message) { received << message } }
  end

  let(:lock) { Mutex.new }
  let(:transport) { instance_double(Bitflyer::Realtime::Transport, closed?: false) }
  let(:token) { Object.new }
  let(:received) { Queue.new }
  let(:started) { Queue.new }
  let(:resume) { Queue.new }

  before do
    lock.synchronize { dispatcher.reset(transport) }
    dispatcher.enqueue_notification(transport, :ready) do
      started << true
      resume.pop
      received << :running
    end
    expect(started.pop(timeout: 5)).to be(true)
  end

  after do
    lock.synchronize { dispatcher.stop }
    resume.close
  end

  it 'accounts for market data and failures independently and shares their delivery order with ready' do
    stub_const("#{described_class}::CALLBACK_QUEUE_LIMIT", 1)
    stub_const("#{described_class}::FAILURE_NOTIFICATION_PAYLOAD_LIMIT", 1)
    dispatcher.enqueue_callback(:ticker, token, 'discarded', transport)
    dispatcher.enqueue_notification(transport, :subscription_failed, bytes: 1) { received << :failure }
    dispatcher.enqueue_notification(transport, :subscription_failed, bytes: 1) { received << :dropped_failure }
    dispatcher.enqueue_callback(:ticker, token, 'dropped', transport)
    lock.synchronize { dispatcher.discard_channel_callbacks(:ticker) }
    dispatcher.enqueue_callback(:ticker, token, 'fresh', transport)
    dispatcher.enqueue_notification(transport, :ready) { received << :ready }
    resume << true

    expect(Array.new(4) { received.pop(timeout: 5) }).to eq([:running, :failure, 'fresh', :ready])
  end

  it 'discards queued work from the previous transport while its running callback finishes' do
    replacement = instance_double(Bitflyer::Realtime::Transport, closed?: false)
    dispatcher.enqueue_callback(:ticker, token, 'stale', transport)
    dispatcher.enqueue_notification(transport, :subscription_failed) { received << :stale_failure }
    lock.synchronize { dispatcher.reset(replacement) }
    dispatcher.enqueue_callback(:ticker, token, 'late', transport)
    dispatcher.enqueue_callback(:ticker, token, 'fresh', replacement)
    resume << true

    expect(Array.new(2) { received.pop(timeout: 5) }).to eq([:running, 'fresh'])
  end
end
