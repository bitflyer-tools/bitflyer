websocket-client-simple
=======================
Simple WebSocket Client for Ruby (original author: @shokai)

- https://github.com/ruby-jp/websocket-client-simple
- https://rubygems.org/gems/websocket-client-simple

[![.github/workflows/test.yml](https://github.com/ruby-jp/websocket-client-simple/actions/workflows/test.yml/badge.svg)](https://github.com/ruby-jp/websocket-client-simple/actions/workflows/test.yml)

Installation
------------

    gem install websocket-client-simple


Usage
-----
```ruby
require 'websocket-client-simple'

ws = WebSocket::Client::Simple.connect 'ws://example.com:8888'

ws.on :message do |msg|
  puts msg.data
end

ws.on :open do
  ws.send 'hello!!!'
end

ws.on :close do |e|
  p e
  exit 1
end

ws.on :error do |e|
  p e
end

loop do
  ws.send STDIN.gets.strip
end
```

`connect` runs a given block before connecting websocket

```ruby
WebSocket::Client::Simple.connect 'ws://example.com:8888' do |ws|
  ws.on :open do
    puts "connect!"
  end

  ws.on :message do |msg|
    puts msg.data
  end
end
```


Sample
------
[websocket chat](https://github.com/ruby-jp/websocket-client-simple/tree/master/sample)


Test
----

    % gem install bundler
    % bundle install
    % export WS_PORT=8888
    % rake test


Contributing
------------
1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
