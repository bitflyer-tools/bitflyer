---
layout: default
title: Architecture
---

# Architecture

Start with [`lib/bitflyer.rb`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer.rb). It exposes the three client
factories and shows how callers enter the HTTP and realtime APIs.

## HTTP requests

The [public client](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/http/public.rb) and
[private client](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/http/private.rb) map Ruby methods and keyword
arguments to API paths and request parameters. Each client delegates requests
to its own `HTTP::Connection` in [`http.rb`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/http.rb). The
connection manages the HTTPS session, signs requests when credentials are
present, and handles response parsing and HTTP errors. Both clients also use
`HTTP::IdPagination` in the same file to paginate `each_execution` and the private client's
`each_balance_history`.

For endpoint changes, start with the client method and its matching specs in
[`spec/bitflyer/http/`](https://github.com/bitflyer-tools/bitflyer/tree/master/spec/bitflyer/http). For shared request or response
behavior, start with [`spec/bitflyer/http_spec.rb`](https://github.com/bitflyer-tools/bitflyer/blob/master/spec/bitflyer/http_spec.rb).

## Realtime events

[`Realtime::Client`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/client.rb) builds callback setters
from the [channel list](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/channels.rb) and delegates
subscriptions to [`WebSocketClient`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/websocket.rb).
`WebSocketClient` handles authentication, subscription acknowledgments,
heartbeats, reconnection, and event delivery. It receives WebSocket events
from the [transport](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/transport.rb), which manages the
TLS socket and uses `websocket-driver` for the WebSocket handshake and frames.

For changes to subscriptions or connection behavior, start with the relevant
specs in [`spec/bitflyer/realtime/`](https://github.com/bitflyer-tools/bitflyer/tree/master/spec/bitflyer/realtime).

### Live order book

`WebSocketClient#order_book` hands out an
[`OrderBook`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/order_book.rb), which merges snapshot
and delta messages under a mutex and exposes immutable `current` and
`top_of_book` views. Each side tracks its best price with a
[`PriceIndex`](https://github.com/bitflyer-tools/bitflyer/blob/master/lib/bitflyer/realtime/order_book/price_index.rb), a binary
heap kept in lockstep with that side's price-to-level `Hash` so the best
price is always the heap root instead of a linear scan.

For order book changes, start with
[`spec/bitflyer/realtime/order_book_spec.rb`](https://github.com/bitflyer-tools/bitflyer/blob/master/spec/bitflyer/realtime/order_book_spec.rb)
and [`spec/bitflyer/realtime/order_book/price_index_spec.rb`](https://github.com/bitflyer-tools/bitflyer/blob/master/spec/bitflyer/realtime/order_book/price_index_spec.rb).

## Type signatures

The gem ships RBS declarations from [`sig/`](https://github.com/bitflyer-tools/bitflyer/tree/master/sig). Steep also reads
[`sig-private/`](https://github.com/bitflyer-tools/bitflyer/tree/master/sig-private) when checking the library. When changing the
channel list, run `ruby script/generate_realtime_signatures.rb` to regenerate
the callback setter declarations.
