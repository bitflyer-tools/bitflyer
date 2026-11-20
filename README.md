# bitflyer
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-4-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->
[![Gem Version](https://badge.fury.io/rb/bitflyer.svg)](https://badge.fury.io/rb/bitflyer)
[![Code Climate](https://codeclimate.com/github/bitflyer-tools/bitflyer/badges/gpa.svg)](https://codeclimate.com/github/bitflyer-tools/bitflyer)
[![Libraries.io dependency status for GitHub repo](https://img.shields.io/librariesio/github/bitflyer-tools/bitflyer.svg)](https://libraries.io/github/bitflyer-tools/bitflyer)
![](http://ruby-gem-downloads-badge.herokuapp.com/bitflyer?type=total)
![GitHub](https://img.shields.io/github/license/bitflyer-tools/bitflyer.svg)

bitflyer is a wrapper interface of [Bitflyer lightning API](https://lightning.bitflyer.jp/docs)  

## Installation

Requires Ruby 3.3 or later.

```sh
gem install bitflyer
```

## Quick start

After installing the gem, run this command to print the public BTC/JPY order book snapshot. The public client works without API credentials.

```sh
ruby -r bitflyer -e 'p Bitflyer.http_public_client.board(product_code: "BTC_JPY")'
```

## Usage

See https://lightning.bitflyer.jp/docs for details.

### HTTP API

See [public.rb](./lib/bitflyer/http/public.rb) / [private.rb](./lib/bitflyer/http/private.rb) for method definition.

HTTP responses outside the 2xx range raise `Bitflyer::HTTP::ResponseError`. The error provides
the numeric HTTP status in `status` and the raw response body in `body`.

#### Example

```ruby
require 'bitflyer'

private_client = Bitflyer.http_private_client('YOUR_API_KEY', 'YOUR_API_SECRET')
p private_client.positions # will print your positions
```

Each HTTP client reuses its HTTPS connection across requests. Call `client.close` to release it.
The next request on that client opens a new connection.

#### Stream execution history

`each_execution` on either HTTP client fetches pages on demand and yields one execution at a time
in API response order. It uses the lowest execution ID on each page as the next exclusive `before`
cursor. Pass a saved execution ID as `before` to resume from older records, and use `after` to set
an exclusive lower bound.

```ruby
public_client = Bitflyer.http_public_client
history = public_client.each_execution(product_code: 'BTC_JPY', before: 123_456, count: 50, max_pages: 5)
history.lazy.take(75).each { |execution| p execution }

private_client.each_execution(child_order_acceptance_id: 'YOUR_ORDER_ACCEPTANCE_ID') do |fill|
  p fill
end
```

`max_pages` defaults to 10 requests per traversal. Set it to 0 to skip fetching. Iteration also
stops when a page is empty, when the cursor stops moving backward, or when the caller stops
consuming the enumerator. Request errors propagate to the caller.

### Realtime API

#### Public events

Accessor format is like `{event_name}_{product_code}`.
You can set lambda to get realtime events.

`{event_name}` and `{product_code}` are defined in [channels.rb](./lib/bitflyer/realtime/channels.rb).

#### Private events

To subscribe to the private `child_order_events` and `parent_order_events`, pass your API key and secret when creating the `realtime_client`.

#### Connection status monitoring

The `ready` callback is called when the `realtime_client` is ready to receive events (after the socket connection is established, the optional authentication has succeeded, and the channels have been subscribed). If connection is lost, the `disconnected` callback is called, and reconnection is attempted automatically. When the connection is restored and the server acknowledges all subscriptions for that setup, `ready` is called again. If the server rejects a setup subscription, `subscription_failed` receives the channel name as a symbol and the server error. That setup skips `ready`.
If setup finishes before registration, assigning `ready` delivers the pending notification synchronously, once per connection.

A `StandardError` raised by `disconnected` is reported to standard error. Automatic reconnection continues when enabled.

If the server rejects authentication, the client closes the connection and passes a `RuntimeError` with the server response to `disconnected`. Authentication rejection stops automatic reconnection.

Call `client.shutdown` when you finish using a realtime client. It stops automatic reconnection, closes the connection, and stops the monitoring thread. You can call it more than once, including from a `ready` or subscription callback.
Concurrent calls wait for the connection to close.
Calling `shutdown` from a subscription callback skips any remaining events in the current WebSocket frame.

#### Examples

For public events only:
```ruby
client = Bitflyer.realtime_client
client.ticker_btc_jpy = ->(json){ p json } # will print json object
client.executions_btc_jpy = ->(json){ p json }
# ...
```

For both public and private events:
```ruby
client = Bitflyer.realtime_client('YOUR_API_KEY', 'YOUR_API_SECRET')
# Private events:
client.child_order_events = ->(json){ p json }
client.parent_order_events = ->(json){ p json }
# Public events:
client.ticker_btc_jpy = ->(json){ p json }
client.executions_btc_jpy = ->(json){ p json }
# ...
```

Connection monitoring:
```ruby
client = Bitflyer.realtime_client
client.ready = -> { p "Client is ready to receive events" }
client.disconnected = ->(error) { p "Client got disconnected" }
client.subscription_failed = ->(channel, error) { p [channel, error] }
```

### Type signatures

The gem ships [RBS](https://github.com/ruby/rbs) signatures in `sig/`, so [Steep](https://github.com/soutaro/steep) and other RBS-based tools
can check code that uses it. API responses are parsed JSON and are typed as `untyped`.

To type check the gem itself:

```sh
bundle config set --local with typecheck
bundle install
bundle exec rake steep
```

After changing the realtime channel list, regenerate the callback setter signatures with
`ruby script/generate_realtime_signatures.rb`. CI checks that the shipped declarations are up to date.


## Contributing

Bug reports and pull requests are welcome on GitHub. See the [contributing guide](CONTRIBUTING.md) for setup and checks. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).


## Contributors ✨

Thanks goes to these wonderful people ([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tr>
    <td align="center"><a href="https://github.com/yemartin"><img src="https://avatars.githubusercontent.com/u/139002?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Yves-Eric Martin</b></sub></a><br /><a href="https://github.com/unhappychoice/bitflyer/commits?author=yemartin" title="Code">💻</a></td>
    <td align="center"><a href="http://blog.unhappychoice.com"><img src="https://avatars.githubusercontent.com/u/5608948?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Yuji Ueki</b></sub></a><br /><a href="https://github.com/unhappychoice/bitflyer/commits?author=unhappychoice" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/fkshom"><img src="https://avatars.githubusercontent.com/u/1889118?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Shoma FUKUDA</b></sub></a><br /><a href="https://github.com/unhappychoice/bitflyer/commits?author=fkshom" title="Code">💻</a></td>
    <td align="center"><a href="http://shidetake.com"><img src="https://avatars.githubusercontent.com/u/1559558?v=4?s=100" width="100px;" alt=""/><br /><sub><b>shidetake</b></sub></a><br /><a href="https://github.com/unhappychoice/bitflyer/commits?author=shidetake" title="Code">💻</a></td>
  </tr>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!

## Author

[@unhappychoice](https://unhappychoice.com)
