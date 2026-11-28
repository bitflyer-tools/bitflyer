---
layout: default
title: Getting started
---

# Getting started

Use the bitflyer Ruby gem to list available markets and fetch an order book from
the bitFlyer Lightning public HTTP API. These requests require no API key.

## Install the gem

With Ruby 3.3 or later, install the gem from RubyGems:

```sh
gem install bitflyer
```

If you already manage your application's dependencies with Bundler, run
`bundle add bitflyer` instead. Run the script below with
`bundle exec ruby market_snapshot.rb` in that application.

## List markets and fetch an order book

Save the following as `market_snapshot.rb`:

```ruby
require 'bitflyer'
require 'pp'

client = Bitflyer.http_public_client

puts 'Available markets:'
pp client.markets

product_code = ARGV.fetch(0, 'BTC_JPY')
puts "Order book for #{product_code}:"
pp client.board(product_code: product_code)
```

Run it with the default product code:

```sh
ruby market_snapshot.rb
```

The script prints the market list followed by a snapshot with bids (buy
orders) and asks (sell orders). To fetch another market, pass one of the
`product_code` values from the market list as the first argument:

```sh
ruby market_snapshot.rb ETH_JPY
```

See the [README usage examples](https://github.com/bitflyer-tools/bitflyer/blob/master/README.md#usage) for authenticated requests
and realtime subscriptions. See [Troubleshooting](troubleshooting.md) if a
request or subscription fails.
