# bitflyer
[![Gem Version](https://badge.fury.io/rb/bitflyer.svg)](https://badge.fury.io/rb/bitflyer)
[![Circle CI](https://circleci.com/gh/unhappychoice/bitflyer.svg?style=shield)](https://circleci.com/gh/unhappychoice/bitflyer)
[![Code Climate](https://codeclimate.com/github/unhappychoice/bitflyer/badges/gpa.svg)](https://codeclimate.com/github/unhappychoice/bitflyer)
![](http://ruby-gem-downloads-badge.herokuapp.com/bitflyer?type=total)

bitflyer is a wrapper interface of [Bitflyer lightning API](https://lightning.bitflyer.jp/docs)  

## Installation

```sh
gem install bitflyer
```

## Usage

See https://lightning.bitflyer.jp/docs for details.

### HTTP API

#### Example

```ruby 
public_client = Bitflyer.http_public_client
p public_client.board # will print board snapshot
 
private_client = Bitflyer.http_private_client('YOUR_API_KEY', 'YOUR_API_SECRET')
p private_client.positions # will print your positions
```

### Realtime API

Accessor format is like `{event_name}_{product_code}`.
You can set lambda to get realtime events.

#### `event_name`
- board_snapshot
- board
- ticker
- executions

#### `product_code`
- btc_jpy
- fx_btc_jpy
- eth_btc
- bch_btc

#### Example

```ruby
client = Bitflyer.realtime_client
client.ticker_btc_jpy = ->(json){ p json } # will print json object 
client.executions_btc_jpy = ->(json){ p json }
# ... 
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/unhappychoice/bitflyer. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

