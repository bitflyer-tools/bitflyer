# bitflyer

bitflyer is a wrapper interface of [Bitflyer lightning API](https://lightning.bitflyer.jp/docs)  

## Installation

```sh
gem install bitflyer
```

## Usage

### HTTP API

TBD

### Realtime API

API format is like `{event_name}_{product_code}`.

#### `event_name`
- board_snapshot
- board
- ticker
- executions

#### `product_code`
- btc_jpy
- fx_btc_jpy
- eth_btc

#### Example

```ruby
client = Bitflyer::Realtime.new
client.ticker_btc_jpy = ->(json){ p json } # will print json object 
client.executions_btc_jpy = ->(json){ p json }
# ... 
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/unhappychoice/bitflyer. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

