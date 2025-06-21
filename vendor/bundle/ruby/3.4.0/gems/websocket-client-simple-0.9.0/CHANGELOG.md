# Changelog

## Not yet released

## 0.9.0 - 2024-12-31
* Add mutex_m and base46 to runtime dependencies #31

## 0.8.0 - 2023-08-08
* Set `WebSocket.should_raise = true` https://github.com/ruby-jp/websocket-client-simple/pull/25 by @jlaffaye

## 0.7.0 - 2023-08-04
* Expose add accessor `Client#thread` #22 by @jlaffaye
* Rewrite changelog as a Markdown

## 0.6.1 - 2023-03-10
* Make `#open?` safe to use when `@handshake` is `nil` #20 by @cyberarm

## 0.6.0 - 2022-09-22
* Add option `cert_store` for passing cert store to SSLSocket context #12 by @DerekStride
* Set `OpenSSL::SSL::SSLSocket#sync_close` to `true` #12 by @DerekStride

## 0.5.1 - 2022-01-01
* Add `closed?` method to `WebSocket::Client::Simple` #8 by @fuyuton
* rescue when `OpenSSL::SSL::SSLError` raised #10 by @fuyuton

## 0.5.0 - 2021-12-31
* Change TLS context defaults to system's default. The previous defaults were `ssl_version=SSLv23` and `verify_mode=VERIFY_NONE`, which are insecure nowadays. #5
  * thank you for contributing @eagletmt
* Made the necessary changes to use SNI. #6
  * thank you for contributing @fuyuton

## 0.4.0 - 2021-12-30
* Drop support of ruby 2.5 or older versions as explicit.

## 0.3.1 - 2021-12-30
* The development of this repository has moved to https://github.com/ruby-jp/websocket-client-simple

## 0.3.0 - 2016-12-30
* `connect` method runs a given block before connecting WebSocket  [#12](https://github.com/shokai/websocket-client-simple/issues/12)
  * thank you for suggestion @codekitchen

## 0.2.5 - 2016-02-18
* bugfixed sending when broken pipe [#15](https://github.com/shokai/websocket-client-simple/pull/15)
* add `:verify_mode` option for SSL Context [#14](https://github.com/shokai/websocket-client-simple/pull/14)
  * thank you for contributing @michaelvilensky

## 0.2.4 - 2015-11-12
* support handshake headers  [#11](https://github.com/shokai/websocket-client-simple/pull/11)
  * thank you for contributing @mathieugagne

## 0.2.3 - 2015-10-26
* kill thread at end of method [#10](https://github.com/shokai/websocket-client-simple/pull/10)
  * thank you for contributing @hansy

## 0.2.2 - 2014-11-18
* bugfix socket reading

## 0.2.0 - 2014-06-07
* SSL support with `wss://` and `https://` scheme [#6](https://github.com/shokai/websocket-client-simple/pull/6)
  * thank you for contributing @mallowlabs

## 0.1.0 - 2014-05-08
* add accessor `Client#handshake` [#5](https://github.com/shokai/websocket-client-simple/issues/5)
* bugfix socket reading

## 0.0.9 - 2014-04-03
* emit `error` in receive thread
* rescue only `Errno::EPIPE`, not all Errors

## 0.0.8 - 2014-01-29
* bugfix `Client#close` #4

## 0.0.7 - 2014-01-29
* send CLOSE frame in `Client#close` [#4](https://github.com/shokai/websocket-client-simple/issues/4)
## 0.0.6 - 2014-01-17
* add function `Client#open?`

## 0.0.5 - 2013-03-23
* kill read thread on close

## 0.0.4 - 2013-03-23
* fix sample and README

## 0.0.3 - 2013-03-23
* `:type => :text` option in send

## 0.0.2 - 2013-03-22
* remove unnecessary sleep

## 0.0.1 - 2013-03-22
* release
