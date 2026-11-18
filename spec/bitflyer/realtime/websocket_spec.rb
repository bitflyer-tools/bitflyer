# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'timeout'

RSpec.describe Bitflyer::Realtime::WebSocketClient do
  let(:key) { OpenSSL::PKey::RSA.new(2048) }
  let(:ca_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:trusted_ca) { certificate('Test CA', 1, ca_key) }
  let(:trusted_certificate) { certificate('localhost', 2, key, issuer: trusted_ca) }
  let(:wrong_hostname_certificate) { certificate('other.example', 3, key, issuer: trusted_ca) }
  let(:untrusted_certificate) { certificate('localhost', 4, key) }
  let(:listener) { TCPServer.new('127.0.0.1', 0) }
  let(:host) { "https://localhost:#{listener.addr[1]}" }

  around do |example|
    previous_cert_file = ENV['SSL_CERT_FILE']
    Tempfile.create('realtime-trust') do |file|
      file.write(trusted_ca.to_pem)
      file.flush
      ENV['SSL_CERT_FILE'] = file.path
      example.run
    end
  ensure
    ENV['SSL_CERT_FILE'] = previous_cert_file
  end

  before do
    allow_any_instance_of(described_class).to receive(:start_monitoring)
  end

  after do
    @monitor&.kill&.join
    @client&.websocket_client&.close
    @server&.kill&.join
    listener.close
  end

  it 'authenticates over a trusted connection for the expected hostname' do
    connect_to_trusted_server
  end

  it 'closes the connection when the TLS peer stalls the WebSocket upgrade' do
    stub_const('Bitflyer::Realtime::WebSocketTransport::HANDSHAKE_TIMEOUT', 0.2)
    serve(trusted_certificate) { |socket| socket.read }
    @client = connect_client

    expect(server_result).to start_with('GET /socket.io/?transport=websocket HTTP/1.1')
    expect(@client.websocket_client).not_to be_active
  end

  {
    untrusted_certificate: /self-signed certificate/,
    wrong_hostname_certificate: /hostname mismatch/
  }.each do |invalid_certificate, verification_error|
    it "rejects #{invalid_certificate.to_s.tr('_', ' ')} before the WebSocket upgrade" do
      serve(public_send(invalid_certificate))
      expect { connect_client }.to raise_error(OpenSSL::SSL::SSLError, verification_error)
      expect(server_result).to eq(:tls_rejected)
    end

    it "rejects #{invalid_certificate.to_s.tr('_', ' ')} on reconnect and allows a later trusted retry" do
      connect_to_trusted_server
      @client.websocket_client.close

      serve(public_send(invalid_certificate))
      allow(@client).to receive(:start_monitoring).and_call_original
      @monitor = @client.start_monitoring
      expect(server_result).to eq(:tls_rejected)

      serve(trusted_certificate)
      expect_authentication
    end
  end

  def connect_client
    described_class.new(host: host, key: 'test-api-key', secret: 'test-api-secret')
  end

  def connect_to_trusted_server
    serve(trusted_certificate)
    @client = connect_client
    expect_authentication
  end

  def expect_authentication
    expect(server_result).to start_with('420["auth",{"api_key":"test-api-key"')
  end

  def server_result
    Timeout.timeout(5) { @server.value }
  end

  def serve(cert, &handler)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    server = OpenSSL::SSL::SSLServer.new(listener, context)
    @server = Thread.new do
      begin
        socket = server.accept
      rescue OpenSSL::SSL::SSLError
        next :tls_rejected
      end
      handler ? handler.call(socket) : receive_authentication(socket)
    ensure
      socket&.close
    end
  end

  def receive_authentication(socket)
    driver = WebSocket::Driver.server(socket)
    authentication = nil
    driver.on(:connect) do
      driver.start
      driver.text('0{}')
    end
    driver.on(:message) { |event| authentication = event.data }
    driver.parse(socket.readpartial(4096)) until authentication
    authentication
  end

  def certificate(hostname, serial, public_key, issuer: nil)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{hostname}")
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = public_key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    if public_key == ca_key
      cert.add_extension(extensions.create_extension('basicConstraints', 'CA:TRUE', true))
    else
      cert.add_extension(extensions.create_extension('subjectAltName', "DNS:#{hostname}"))
    end
    cert.sign(issuer ? ca_key : public_key, OpenSSL::Digest.new('SHA256'))
  end
end

describe Bitflyer::Realtime::WebSocketClient, 'outage recovery' do
  let(:socket) { instance_double(Bitflyer::Realtime::WebSocketTransport, open?: true, active?: true, start: nil, send: nil) }
  let(:ticks) { Queue.new }
  let(:waiting) { Queue.new }
  let(:handlers) { {} }

  before do
    tick_queue = ticks
    waiting_queue = waiting
    allow(socket).to receive(:on) { |event, &handler| handlers[event] = handler }
    allow(Bitflyer::Realtime::WebSocketTransport).to receive(:new) do
      attempt = @attempts.shift
      raise attempt if attempt.is_a?(Exception)

      attempt
    end
    allow_any_instance_of(described_class).to receive(:sleep) do
      waiting_queue.push(Thread.current)
      tick_queue.pop
    end
    allow($stdout).to receive(:puts)
  end

  after do
    @monitor&.kill
    @monitor&.join
  end

  def wait_for_monitor
    @monitor = Timeout.timeout(5) { waiting.pop }
  end

  def tick_monitor
    ticks.push(true)
    wait_for_monitor
  end

  def receive_message(data)
    handlers.fetch(:message).call(double('WebSocket payload', data: data))
  end

  it 'replays subscriptions registered during the initial outage once the session is ready' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    events = []
    client.ticker_btc_jpy = ->(event) { events << event }
    tick_monitor
    client.executions_btc_jpy = ->(_event) {}
    expect(socket).not_to have_received(:send)

    receive_message('0{}')
    expect(socket).to have_received(:send).with('42["subscribe","lightning_ticker_BTC_JPY"]').once
    expect(socket).to have_received(:send).with('42["subscribe","lightning_executions_BTC_JPY"]').once

    receive_message('42["lightning_ticker_BTC_JPY",{"ltp":100}]')
    expect(events).to eq([{ 'ltp' => 100 }])
  end

  it 'keeps the monitor alive after a refused retry' do
    @attempts = [SocketError.new('DNS lookup failed'), Errno::ECONNREFUSED.new, socket]
    client = Bitflyer.realtime_client
    wait_for_monitor

    tick_monitor
    expect(@monitor).to be_alive
    expect(client.websocket_client.websocket_client).to be_nil

    tick_monitor
    expect(client.websocket_client.websocket_client).to eq(socket)
  end

  it 'waits for authentication before replaying private subscriptions' do
    @attempts = [SocketError.new('DNS lookup failed'), socket]
    client = Bitflyer.realtime_client('key', 'secret')
    wait_for_monitor
    client.child_order_events = ->(_event) {}
    tick_monitor

    receive_message('0{}')
    expect(socket).not_to have_received(:send).with('42["subscribe","child_order_events"]')

    receive_message('430[null]')
    expect(socket).to have_received(:send).with('42["subscribe","child_order_events"]').once
  end
end
