require 'bitflyer/version'
require 'bitflyer/http'
require 'bitflyer/realtime'

module Bitflyer
  def realtime_client
    Bitflyer::Realtime::Client.new
  end

  def http_public_client
    Bitflyer::HTTP::Public::Client.new
  end

  def http_private_client
    Bitflyer::HTTP::Private::Client.new
  end

  module_function :realtime_client, :http_public_client, :http_private_client
end
