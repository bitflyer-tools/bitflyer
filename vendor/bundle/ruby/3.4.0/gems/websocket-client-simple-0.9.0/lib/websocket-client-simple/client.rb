module WebSocket
  module Client
    module Simple

      def self.connect(url, options={})
        client = ::WebSocket::Client::Simple::Client.new
        yield client if block_given?
        client.connect url, options
        return client
      end

      class Client
        include EventEmitter
        attr_reader :url, :handshake, :thread

        def connect(url, options={})
          return if @socket
          @url = url
          uri = URI.parse url
          @socket = TCPSocket.new(uri.host,
                                  uri.port || (uri.scheme == 'wss' ? 443 : 80))
          if ['https', 'wss'].include? uri.scheme
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.ssl_version = options[:ssl_version] if options[:ssl_version]
            ctx.verify_mode = options[:verify_mode] if options[:verify_mode]
            cert_store = options[:cert_store] || OpenSSL::X509::Store.new
            cert_store.set_default_paths
            ctx.cert_store = cert_store
            @socket = ::OpenSSL::SSL::SSLSocket.new(@socket, ctx)
            @socket.sync_close = true
            @socket.hostname = uri.host
            @socket.connect
          end
          ::WebSocket.should_raise = true
          @handshake = ::WebSocket::Handshake::Client.new :url => url, :headers => options[:headers]
          @handshaked = false
          @pipe_broken = false
          frame = ::WebSocket::Frame::Incoming::Client.new
          @closed = false
          once :__close do |err|
            close
            emit :close, err
          end

          @thread = Thread.new do
            while !@closed do
              begin
                unless recv_data = @socket.getc
                  sleep 1
                  next
                end
                unless @handshaked
                  @handshake << recv_data
                  if @handshake.finished?
                    @handshaked = true
                    emit :open
                  end
                else
                  frame << recv_data
                  while msg = frame.next
                    emit :message, msg
                  end
                end
              rescue => e
                emit :error, e
              end
            end
          end

          @socket.write @handshake.to_s
        end

        def send(data, opt={:type => :text})
          return if !@handshaked or @closed
          type = opt[:type]
          frame = ::WebSocket::Frame::Outgoing::Client.new(:data => data, :type => type, :version => @handshake.version)
          begin
            @socket.write frame.to_s
          rescue Errno::EPIPE => e
            @pipe_broken = true
            emit :__close, e
          rescue OpenSSL::SSL::SSLError => e
            @pipe_broken = true
            emit :__close, e
          end
        end

        def close
          return if @closed
          if !@pipe_broken
            send nil, :type => :close
          end
          @closed = true
          @socket.close if @socket
          @socket = nil
          emit :__close
          Thread.kill @thread if @thread
        end

        def open?
          @handshake&.finished? and !@closed
        end

        def closed?
          @closed
        end

      end

    end
  end
end
