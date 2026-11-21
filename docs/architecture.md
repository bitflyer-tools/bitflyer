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
`WebSocketClient` handles authentication, subscription acknowledgments,
heartbeats, reconnection, and event delivery. It receives WebSocket events
from the [transport](../lib/bitflyer/realtime/transport.rb), which manages the
TLS socket and uses `websocket-driver` for the WebSocket handshake and frames.

For changes to subscriptions or connection behavior, start with the relevant
specs in [`spec/bitflyer/realtime/`](../spec/bitflyer/realtime).

## Type signatures

The gem ships RBS declarations from [`sig/`](../sig). Steep also reads
[`sig-private/`](../sig-private) when checking the library. When changing the
channel list, run `ruby script/generate_realtime_signatures.rb` to regenerate
the callback setter declarations.
