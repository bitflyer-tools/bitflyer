# Architecture

Start with [`lib/bitflyer.rb`](../lib/bitflyer.rb). It exposes the three client
factories and shows how callers enter the HTTP and realtime APIs.

## HTTP requests

The [public client](../lib/bitflyer/http/public.rb) and
[private client](../lib/bitflyer/http/private.rb) map Ruby methods and keyword
arguments to API paths and request parameters. Each client delegates requests
to its own `HTTP::Connection` in [`http.rb`](../lib/bitflyer/http.rb). The
connection manages the HTTPS session, signs requests when credentials are
present, and handles response parsing and HTTP errors. Both clients also use
`HTTP::IdPagination` in the same file to paginate `each_execution` and the private client's
`each_balance_history`.

For endpoint changes, start with the client method and its matching specs in
[`spec/bitflyer/http/`](../spec/bitflyer/http). For shared request or response
behavior, start with [`spec/bitflyer/http_spec.rb`](../spec/bitflyer/http_spec.rb).

## Realtime events

[`Realtime::Client`](../lib/bitflyer/realtime/client.rb) builds callback setters
from the [channel list](../lib/bitflyer/realtime/channels.rb) and delegates
subscriptions to [`WebSocketClient`](../lib/bitflyer/realtime/websocket.rb).
`WebSocketClient` wires together the realtime collaborators:

- [Socket.IO session](../lib/bitflyer/realtime/socket_io_session.rb) decodes
  packets and tracks setup and authentication.
- [Connection lifecycle](../lib/bitflyer/realtime/connection_lifecycle.rb)
  manages connection attempts, shutdown, and retry backoff. Its
  [transport](../lib/bitflyer/realtime/transport.rb) manages the TLS socket
  and uses `websocket-driver` for the WebSocket handshake and frames.
- [Heartbeat](../lib/bitflyer/realtime/heartbeat.rb) tracks ping writes and
  pong deadlines.
- [Subscription registry](../lib/bitflyer/realtime/subscription_registry.rb)
  tracks callbacks and acknowledgment deadlines. The
  [subscription session](../lib/bitflyer/realtime/subscription_session.rb)
  coordinates subscriptions, readiness, and routing for the active transport.
- [Callback dispatcher](../lib/bitflyer/realtime/callback_dispatcher.rb)
  delivers queued events and disconnect notifications on separate workers.
- [Order book feeds](../lib/bitflyer/realtime/order_book_feeds.rb) register
  books and route snapshots and deltas.

Operations that need both locks acquire the lifecycle lock before the
subscription lock. Transport replacement resets the session and clears
queued callbacks while both locks are held. Writes and user callbacks
run outside those locks.

For changes to subscriptions or connection behavior, start with the relevant
specs in [`spec/bitflyer/realtime/`](../spec/bitflyer/realtime).

### Live order book

`WebSocketClient#order_book` hands out an
[`OrderBook`](../lib/bitflyer/realtime/order_book.rb), which merges snapshot
and delta messages under a mutex and exposes immutable `current` and
`top_of_book` views. Each side tracks its best price with a
[`PriceIndex`](../lib/bitflyer/realtime/order_book/price_index.rb), a binary
heap kept in lockstep with that side's price-to-level `Hash` so the best
price is always the heap root instead of a linear scan.

For order book changes, start with
[`spec/bitflyer/realtime/order_book_spec.rb`](../spec/bitflyer/realtime/order_book_spec.rb)
and [`spec/bitflyer/realtime/order_book/price_index_spec.rb`](../spec/bitflyer/realtime/order_book/price_index_spec.rb).

## Type signatures

The gem ships RBS declarations from [`sig/`](../sig). Steep also reads
[`sig-private/`](../sig-private) when checking the library. When changing the
channel list, run `ruby script/generate_realtime_signatures.rb` to regenerate
the callback setter declarations.
