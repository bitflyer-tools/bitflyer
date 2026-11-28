---
layout: default
title: Troubleshooting
---

# Troubleshooting

## An HTTP request raises `Bitflyer::HTTP::ResponseError`

Read `error.status` for the HTTP status code and `error.body` for the raw
response from bitFlyer. For a failed private request, try the
[public market walkthrough](getting-started.md) to check whether public
requests work without credentials.

## Execution history stops sooner than expected

`each_execution` makes up to 10 requests by default. Pass a larger
`max_pages` to increase that limit. Use a non-negative integer, since
`max_pages: 0` skips all requests. If the enumerator reaches an empty page
or the cursor stops moving backward, raising the page limit has no effect.
See [Stream execution history](https://github.com/bitflyer-tools/bitflyer/blob/master/README.md#stream-execution-history) for
cursor examples and the public endpoint's history limit.

## Realtime authentication fails

Set the [`disconnected` callback](https://github.com/bitflyer-tools/bitflyer/blob/master/README.md#connection-status-monitoring)
to inspect the authentication error. If bitFlyer rejects authentication, the
client closes the connection and stops reconnecting. Check the API key and
secret, then call `shutdown` and create a new realtime client with the
corrected credentials.

## The realtime order book returns `nil` after a disconnect

`book.current` returns `nil` while the client waits for a fresh snapshot.
Handle `nil` before reading bids, asks, or the spread. Keep using the same
book while the client reconnects and restores its subscriptions. See
[Live order book](https://github.com/bitflyer-tools/bitflyer/blob/master/README.md#live-order-book) for an example.
