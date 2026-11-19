# Architecture

Start with [lib/bitflyer.rb](../lib/bitflyer.rb). It exposes three factory
methods. `http_public_client` and `http_private_client` create clients
for HTTP requests. `realtime_client` creates a client that delivers
WebSocket events to registered callbacks.

## HTTP clients

[Public::Client](../lib/bitflyer/http/public.rb) maps market data methods to
HTTP endpoints. [Private::Client](../lib/bitflyer/http/private.rb) maps
authenticated methods for account data and orders. Both delegate to
[HTTP::Connection](../lib/bitflyer/http.rb), which encodes requests, signs
requests when both credentials are present, and handles responses. Each
client owns a connection that reuses its HTTPS session across requests.
The same file contains the shared pagination logic behind both
`each_execution` methods.

For an endpoint change, start with the public or private client, then check
its matching [request specs](../spec/bitflyer/http) and
[RBS signatures](../sig/bitflyer/http). For a change to request signing,
response handling, or connection reuse, start with `HTTP::Connection`.

## Realtime client

[Realtime::Client](../lib/bitflyer/realtime/client.rb) defines callback
setters from the list in [channels.rb](../lib/bitflyer/realtime/channels.rb)
and forwards subscriptions to
[WebSocketClient](../lib/bitflyer/realtime/websocket.rb). That class manages
Socket.IO setup, authentication, event dispatch, heartbeats, reconnects,
and shutdown. [Transport](../lib/bitflyer/realtime/transport.rb) wraps the
underlying WebSocket library and handles socket cleanup on connection errors
and shutdown.

For a channel change, start with `channels.rb` and run the
[signature generator](../script/generate_realtime_signatures.rb) to update
the RBS callback setters. For changes to setup, callbacks, or reconnects,
start with `WebSocketClient` and the
[realtime specs](../spec/bitflyer/realtime).
