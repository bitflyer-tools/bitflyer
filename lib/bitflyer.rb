# frozen_string_literal: true

require 'bitflyer/version'
require 'bitflyer/http'
require 'bitflyer/realtime'

module Bitflyer
  def realtime_client(key = nil, secret = nil)
    Bitflyer::Realtime::Client.new(key, secret)
  end

  def http_public_client
    Bitflyer::HTTP::Public::Client.new
  end

  def http_private_client(key, secret)
    Bitflyer::HTTP::Private::Client.new(key, secret)
  end

  module_function :realtime_client, :http_public_client, :http_private_client
end
