# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'

describe 'HTTPS connection reuse' do
  let(:client) { Bitflyer.http_public_client }
  let(:listener) { TCPServer.new('127.0.0.1', 0) }
  let(:context) { ssl_context }
  let(:server) { OpenSSL::SSL::SSLServer.new(listener, context) }
  let(:cert_store) { OpenSSL::X509::Store.new.tap { |store| store.add_cert(context.cert) } }

  before do
    stub_const('Bitflyer::HTTP::BASE_URL', "https://localhost:#{listener.addr[1]}")
    allow(Net::HTTP).to receive(:start).and_wrap_original do |start, *args, **options|
      start.call(*args, **options, cert_store: cert_store, open_timeout: 5, read_timeout: 5)
    end
  end

  after do
    client.close
    listener.close
    @server_thread&.kill
    @server_thread&.join
  end

  it 'serves sequential and concurrent ticker requests over one connection and closes it on demand' do
    serve do
      with_socket do |socket|
        4.times { respond(socket) }
        socket.gets
      end
    end

    2.times { expect(client.ticker).to eq('status' => 'ok') }
    requests = Array.new(2) { Thread.new { client.ticker } }
    expect(requests.map(&:value)).to eq([{ 'status' => 'ok' }] * 2)
    2.times { client.close }
    expect(server_result).to be_nil
  end

  it 'reconnects after the server closes an idle connection' do
    closed = Queue.new
    serve do
      with_socket { |socket| respond(socket) }
      closed << true
      with_socket { |socket| respond(socket) }
    end

    expect(client.ticker).to eq('status' => 'ok')
    Timeout.timeout(5) { closed.pop }
    expect(client.ticker).to eq('status' => 'ok')
    server_result
  end

  it 'reuses the connection after an HTTP error response' do
    serve do
      with_socket do |socket|
        read_request(socket)
        socket.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
        respond(socket)
      end
    end

    expect { client.ticker }.to raise_error(Bitflyer::HTTP::ResponseError) { |error|
      expect(error).to have_attributes(status: 503, body: '')
    }
    expect(client.ticker).to eq('status' => 'ok')
    server_result
  end

  context 'with a private client' do
    let(:client) { Bitflyer.http_private_client('key', 'secret') }

    it 'does not replay a POST if the server closes before responding' do
      serve do
        post_request = with_socket do |socket|
          respond(socket)
          read_request(socket)
        end
        next_request = with_socket { |socket| respond(socket) }
        [post_request, next_request]
      end

      expect(client.balance).to eq('status' => 'ok')
      expect { client.cancel_all_child_orders }.to raise_error(EOFError)
      expect(client.balance).to eq('status' => 'ok')
      expect(server_result).to eq(['POST /v1/me/cancelallchildorders HTTP/1.1',
                                   'GET /v1/me/getbalance HTTP/1.1'])
    end
  end

  def ssl_context
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=localhost')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    OpenSSL::SSL::SSLContext.new.tap do |ssl|
      ssl.cert = cert
      ssl.key = key
    end
  end

  def serve(&block)
    server
    @server_thread = Thread.new(&block)
  end

  def server_result
    Timeout.timeout(5) { @server_thread.value }
  end

  def with_socket
    socket = server.accept
    yield socket
  ensure
    socket&.close
  end

  def read_request(socket)
    request_line = socket.readline.strip
    content_length = 0
    while (header = socket.readline) != "\r\n"
      name, value = header.split(':', 2)
      content_length = value.to_i if name.casecmp?('Content-Length')
    end
    socket.read(content_length)
    request_line
  end

  def respond(socket)
    request_line = read_request(socket)
    body = '{"status":"ok"}'
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    request_line
  end
end
