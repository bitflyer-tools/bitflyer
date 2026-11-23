# bitflyer
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
[![All Contributors](https://img.shields.io/badge/all_contributors-4-orange.svg?style=flat-square)](#contributors-)
<!-- ALL-CONTRIBUTORS-BADGE:END -->
[![CI](https://github.com/bitflyer-tools/bitflyer/actions/workflows/test.yml/badge.svg?branch=master)](https://github.com/bitflyer-tools/bitflyer/actions/workflows/test.yml)
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

See the [getting started guide](docs/getting-started.md) for a script that lists markets and fetches an order book.

## Features

- Fetch markets, order book snapshots, tickers, executions, and funding rates over public HTTP.
- Read balances and positions and place or cancel orders over authenticated HTTP.
- Iterate through execution and balance history one page at a time.
- Subscribe to live market data and authenticated order events, and track a live order book.

## Usage

See https://lightning.bitflyer.jp/docs for details.

### HTTP API

See [public.rb](./lib/bitflyer/http/public.rb) / [private.rb](./lib/bitflyer/http/private.rb) for method definition.

For a successful (2xx) HTTP response, the client returns the parsed Ruby value if the body is valid JSON.
If the body is non-JSON text or an empty string, the client returns the original string.
If the response has no body, the client returns `nil`.

If the connection closes before the declared body length is received, the client retries a GET
once and raises `EOFError` if the retry is also incomplete. A POST raises `EOFError` without retrying.

Each HTTP request has a 30-second deadline covering the wait for another request on the same client,
connection establishment, the full response, and any GET retry. An expired request raises
`Bitflyer::HTTP::RequestTimeoutError` (a subclass of `Timeout::Error`). If it expires while waiting,
the active request keeps its connection. If it expires while using the connection, the client closes
that connection and the next request opens a new one.

HTTP responses outside the 2xx range raise `Bitflyer::HTTP::ResponseError`. The error provides
the numeric HTTP status in `status` and the raw response body in `body`.

Each HTTP response body is limited to 10 MiB (10,485,760 bytes) after automatic decompression.
Exceeding this limit raises `Bitflyer::HTTP::ResponseTooLargeError` for any HTTP status and closes
the connection. The next request opens a new connection.

`cancel_child_order`, `cancel_parent_order`, and `parent_order` require exactly one
order ID or order acceptance ID. They raise `ArgumentError` before sending a request
if neither identifier or both identifiers are non-nil.

`send_child_order` requires `child_order_type`, `side`, and `size`. A `LIMIT` order also requires
`price`. Missing or nil required values raise `ArgumentError` before an HTTP request is made.

`send_parent_order` takes an array of condition hashes with symbol or string keys.
Provide one condition for `SIMPLE` (the default), two for `IFD` or `OCO`, and three for `IFDOCO`.
An incorrect condition count raises `ArgumentError` before an HTTP request is made.
Each condition requires `product_code`, `condition_type`, `side`, and `size`. `LIMIT` and `STOP_LIMIT` require
`price`, `STOP` and `STOP_LIMIT` require `trigger_price`, and `TRAIL` requires `offset`.
Symbol and string keys may be mixed. Missing or nil required values and keys that collide after
conversion to strings raise `ArgumentError` before an HTTP request is made.

Order quantities and prices accept integers and finite floats. This also applies to the trigger price
in parent order conditions. Pass expiration minutes as integers and `TRAIL` offsets as positive integers. The client
raises `ArgumentError` before sending an order with an unsupported value such as a `BigDecimal`.

#### Example

```ruby
require 'bitflyer'

private_client = Bitflyer.http_private_client('YOUR_API_KEY', 'YOUR_API_SECRET')
p private_client.positions # will print your positions
```

Each HTTP client can reuse its HTTPS connection after up to 10 seconds of idle time if the server
keeps it open. Call `client.close` to release it. The next request on that client opens a new connection.

`withdraw` requires non-`nil` `bank_account_id` and `amount` keywords. The amount must be an integer
or a finite float. Unsupported amounts raise `ArgumentError` before an HTTP request is sent.
Omit `currency_code` to send `JPY`. Passing `currency_code: nil` raises `ArgumentError` before sending the request.
Pass `code` to include a two-factor authentication code when required.

#### Crypto CFD funding rates

Use the public HTTP client to fetch the upcoming funding rate and its UTC settlement time,
or to retrieve past rates in descending order by calculation time.

```ruby
require 'bitflyer'

public_client = Bitflyer.http_public_client
upcoming = public_client.funding_rate(product_code: 'FX_BTC_JPY')
p upcoming.values_at('current_funding_rate', 'next_funding_rate_settledate')

history = public_client.funding_rate_history(
  product_code: 'FX_BTC_JPY',
  from: '2024-04-14T00:00:00',
  to: '2024-04-16T00:00:00',
  count: 10
)
p history
```

Pass `from` and `to` as UTC timestamp strings. Both bounds are optional and apply to
`calculation_date`. The API defaults to 100 records and accepts at most 500 per request.
When you supply `from`, the API selects the oldest matching records up to `count` and
returns them newest first.

#### Crypto CFD margin change history

Use the private HTTP client to fetch one page of margin changes. The optional `count`
sets the page size, and `before` and `after` set exclusive bounds on record IDs.

```ruby
require 'bitflyer'

private_client = Bitflyer.http_private_client('YOUR_API_KEY', 'YOUR_API_SECRET')
history = private_client.collateral_history(count: 10)
history.each do |record|
  p record.values_at('date', 'currency_code', 'change', 'amount', 'reason_code')
end
```

Each record includes the margin change in `change`, the resulting balance in `amount`,
and the reason code and timestamp as returned by bitFlyer.
See the [margin change history API documentation](https://lightning.bitflyer.com/docs?lang=en#get-margin-change-history).

#### Stream execution history

`each_execution` on either HTTP client fetches pages on demand and yields one execution at a time
in API response order. It uses the lowest execution ID on each page as the next exclusive `before`
cursor. Pass a saved execution ID as `before` to resume from older records, and use `after` to set
an exclusive lower bound.

The [public `/v1/executions` endpoint](https://lightning.bitflyer.com/docs?lang=en#execution-history)
limits history retrieved with `before` to the most recent 31 days. To resume a public backfill,
use the saved ID of an execution within that window. A saved ID cannot retrieve older history.

```ruby
public_client = Bitflyer.http_public_client
# Set BITFLYER_SAVED_EXECUTION_ID to a saved BTC_JPY execution ID from the past 31 days.
saved_execution_id = Integer(ENV.fetch('BITFLYER_SAVED_EXECUTION_ID'), 10)
history = public_client.each_execution(product_code: 'BTC_JPY', before: saved_execution_id, count: 50, max_pages: 5)
history.lazy.take(75).each { |execution| p execution }

private_client.each_execution(child_order_acceptance_id: 'YOUR_ORDER_ACCEPTANCE_ID') do |fill|
  p fill
end
```

`max_pages` defaults to 10 requests per traversal. Set it to 0 to skip fetching. Iteration also
stops when a page is empty, when the cursor stops moving backward, or when the caller stops
consuming the enumerator. Request errors propagate to the caller.

#### Stream account balance history

Use `each_balance_history` on the private HTTP client to fetch pages on demand and yield one
balance entry at a time in API response order. Each page's lowest ID becomes the next
exclusive `before` cursor. To resume an older-history export, pass the last successfully
processed ID for the same currency as `before`. Use `after` to set an exclusive lower bound.

```ruby
require 'bitflyer'

private_client = Bitflyer.http_private_client('YOUR_API_KEY', 'YOUR_API_SECRET')
saved_balance_id = Integer(ENV.fetch('BITFLYER_SAVED_BALANCE_ID'), 10)
private_client.each_balance_history(currency_code: 'JPY', before: saved_balance_id, count: 50, max_pages: 5) do |entry|
  p entry
end
```

Omit the block to get an enumerator. `max_pages` defaults to 10 and accepts 0 to skip fetching.
Iteration stops when the budget is reached, a page is empty, the cursor stops moving backward,
or the caller stops consuming entries. Request errors propagate to the caller.

### Realtime API

#### Public events

Accessor format is like `{event_name}_{product_code}`.
You can set lambda to get realtime events.

`{event_name}` and `{product_code}` are defined in [channels.rb](./lib/bitflyer/realtime/channels.rb).

#### Live order book

Use `order_book` to track a product's snapshot and delta channels on the realtime client.
Repeated calls for the same product return the same book. The subscriptions stay active
for the lifetime of the client and can coexist with raw board callbacks.
Call `order_book` again for the same product to retry any rejected or timed-out feed
on the current connection. Existing raw callbacks are preserved.

```ruby
client = Bitflyer.realtime_client
book = client.order_book(product_code: 'BTC_JPY')

begin
  loop do
    if (top = book.top_of_book)
      p [top.best_bid&.price, top.best_ask&.price, top.spread]
    else
      puts 'Waiting for an order book snapshot'
    end
    sleep 1
  end
ensure
  client.shutdown
end
```

`book.ready?` reports whether the book has received a snapshot after the server acknowledged
the delta subscription on the current connection.
`book.top_of_book` returns an immutable view of the best bid and ask from the same book state
without copying or sorting the full depth. Each best level has a `price` and `size`, and is
`nil` when its side is empty. `spread` is the best ask price minus the best bid price when
both exist, and `nil` otherwise.

`book.current` returns an immutable full-depth view with frozen `bids` (highest price first)
and `asks` (lowest price first), along with the same best-level and spread accessors.
Both methods return `nil` before the first snapshot, after shutdown, and while waiting
for a fresh snapshot after a disconnect or a delta that fails to apply. The book ignores
deltas while waiting for a fresh snapshot. Raw board callbacks still receive decoded messages
in arrival order when a book update fails. Views already read stay unchanged as new messages arrive.

Updates with a non-finite or negative price or size invalidate the book until a valid
snapshot arrives. Zero-price levels are ignored, and a zero size removes the level at its price.

See the [snapshot](https://bf-lightning-api.readme.io/docs/realtime-board-snapshot) and
[delta](https://bf-lightning-api.readme.io/docs/realtime-board) channel documentation.

#### Private events

To subscribe to the private `child_order_events` and `parent_order_events`, pass your API key and secret when creating the `realtime_client`.

#### Connection status monitoring

The `ready` callback is called when the `realtime_client` is ready to receive events (after the socket connection is established, the optional authentication has succeeded, and the channels have been subscribed). If connection is lost, the client invalidates the session and delivers `disconnected` on a separate thread. Automatic reconnection can proceed while that callback runs. When the connection is restored and the server acknowledges all subscriptions for that setup, `ready` is called again. If the server rejects a setup subscription, `subscription_failed` receives the channel name as a symbol and the server error. That setup skips `ready`.
During an outage, retry delays increase exponentially, with jitter and a 30-second cap. When the session becomes ready, the retry delay resets.
If setup finishes before registration, assigning `ready` delivers the pending notification synchronously, once per connection.
If any setup subscription acknowledgment is missing when the 10-second deadline is reached, the client closes the connection and retries the registered subscriptions on a new connection. Acknowledgments at or after the deadline cannot make the connection ready.
Each WebSocket write has a 10-second deadline. If a write on an established connection times out or detects a reset, the client reports the error to `disconnected` and replays registered subscriptions after reconnecting.

Each realtime connection attempt has a 10-second deadline for TCP and TLS establishment. If that deadline expires, the client closes the connection and retries automatically.

The client closes and retries a connection if the Socket.IO setup packet or the authentication response takes 10 seconds to arrive. Each step has its own deadline, independent of heartbeat activity.

A `StandardError` raised by `disconnected` is reported to standard error. Automatic reconnection continues when enabled.
Each client runs one asynchronous `disconnected` callback at a time and retains at most one pending
notification. A new notification replaces any pending one while the worker is busy.

If the server rejects authentication, the client closes the connection and passes a `RuntimeError` with the server response to `disconnected`. Authentication rejection stops automatic reconnection.
If the rejection occurs before callback registration, assigning `disconnected` delivers the pending error synchronously, once.

Call `client.shutdown` when you finish using a realtime client. It stops automatic reconnection, closes the connection, and stops the monitoring thread. You can call it more than once, including from a `ready` or subscription callback.
Concurrent calls wait for the connection to close.
Market data callbacks and `subscription_failed` notifications run serially on a separate thread,
so a slow callback does not block heartbeat processing. When an incoming frame or an unsubscribe
completes setup, any registered `ready` callback runs on that same thread.
The queue holds up to 1,024 pending market data callbacks and, independently, up to
1,024 pending `subscription_failed` notifications. Market data also has an 8 MiB
(8,388,608 byte) pending payload budget, measured as the sum of the messages' compact JSON
byte lengths. New entries are dropped when their count limit is reached or, for market
data, when adding the message would exceed the byte budget. Dequeuing or discarding an
entry frees its capacity. The limits exclude the running callback.
Pending entries run in the order they were queued, including `ready` notifications.
Disconnecting or shutting down discards pending callbacks from that connection and allows any
callback already running to finish.

The realtime client's `websocket_client` reference and the WebSocket client's transport reference
(`websocket_client`) are read-only. The realtime lifecycle manages connection replacement.

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

To update a watchlist on the same connection, pass the full Socket.IO channel name
to `subscribe` and `unsubscribe`. A second callback for the same channel replaces the
previous callback. Unsubscribing discards pending events for that subscription,
immediately freeing their queue space, and allows any callback already running to finish.
It also removes the channel from the subscriptions restored on reconnect. For runtime
subscriptions, `subscription_failed` reports server rejections and acknowledgment
timeouts. The 10-second acknowledgment deadline starts when the writer begins
sending the request. The next connection check after the deadline reports the
timeout if the acknowledgment is still pending. Other subscriptions stay active.
Call `subscribe` again to retry a failed channel on the same connection.
An acknowledged or pending subscription is reused when its callback changes.

The WebSocket client's `channel_names` and `channel_callbacks` return frozen snapshots
of the registered channels and their user callbacks, respectively. `channel_names`
also includes channels managed by `order_book`. Use `subscribe` and `unsubscribe`
to change user subscriptions.

```ruby
client = Bitflyer.realtime_client
watchlist = []

update_watchlist = lambda do |product_codes|
  (watchlist - product_codes).each do |code|
    client.unsubscribe("lightning_ticker_#{code}")
  end
  (product_codes - watchlist).each do |code|
    client.subscribe("lightning_ticker_#{code}") { |ticker| p [code, ticker] }
  end
  watchlist = product_codes
end

update_watchlist.call(%w[BTC_JPY ETH_JPY])
# Call again when the user changes the watchlist.
update_watchlist.call(%w[ETH_JPY XRP_JPY])
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
can check code that uses it. API responses are typed as `untyped`.

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
