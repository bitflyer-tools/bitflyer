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
    @client&.shutdown
    @server&.kill&.join
    listener.close
  end

  it 'authenticates over a trusted connection for the expected hostname' do
    connect_to_trusted_server
  end

  it 'closes the connection when the TLS peer stalls the WebSocket upgrade' do
    stub_const('Bitflyer::Realtime::Transport::HANDSHAKE_TIMEOUT', 0.2)
    serve(trusted_certificate) { |socket| socket.read }
    @client = connect_client

    expect(server_result).to start_with('GET /socket.io/?transport=websocket HTTP/1.1')
    expect(@client.websocket_client.thread.join(5)).to be_a(Thread)
    expect(@client.websocket_client).to be_closed
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
      @client.instance_variable_set(:@monitor, @client.__send__(:start_monitoring))
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
