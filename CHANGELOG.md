# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.4.0] - 2021-03-04

### Added

- `elvis`-based style analysis [Paulo Oliveira]

### Changed

- exported types to be so by the module that concerns them [Paulo Oliveira]
- Makefile to something more usable [Paulo Oliveira]
- CI from Travis to GitHub Actions [Paulo Oliveira]
- `rebar.config` to something more maintainable [Paulo Oliveira]

### Fixed

- response queue on lost socket connection to Redis [Luís Rascão]

### Removed

- `include/` [Paulo Oliveira]
- `Emakefile.src` [Paulo Oliveira]
- `mix.exs` [Paulo Oliveira]

### PREVIOUS LOG FORMAT FOLLOWS

## v2.3.1

- Added:
  - Travis CI icon, to help increase consumer confidence [Paulo Oliveira]

## v2.3.0

- Added:
  - compatibility with OTP 23 [Guilherme Andrade]

## v2.2.0

- Changed:
  - source of dependencies to Hex, for quicker builds [Guilherme Andrade]

- Removed:
  - support for OTP 18 [Guilherme Andrade]

## v2.1.0

- Added:
  - exported types (as to avoid importing the `.hrl`) [Paulo Oliveira]

- Changed:
  - CA bundles, to base them on the latest Mozilla Included CA Certificate List
    [Paulo Oliveira]

## v2.0.2

- Fixed:
  - crash log spam when connections are configued to connect on `init/1` and
    fail [Guilherme Andrade]
  - unwarranted dispatch of 'EXIT' to caller upon connection voluntarily
    stopping on `init/1` [Guilherme Andrade]

## v2.0.1

- Added:
  - exposed eredis:start_link/7 [Ricardo Torres]

- Fixed:
  - warning on rebar3 over ssl_verify_fun's missing .app description
    [Paulo Oliveira]

## v2.0.0

- Changed:
  - asynchronous query replies are now uniquely identified (:q_async)
  - reconnect logic
- Removed:
  - unmaintained benchmarking code
- Fixed:
  - crashes upon socket closure
  - bad dispatching of asynchronous pipeline replies (:qp_async)

## v1.3.0

- Added:
  - support for SSL / TLS connections [Guilherme Andrade]
  - asynchronous pipelining [Guilherme Andrade]
  - no-reply pipelining [Guilherme Andrade]
- Fixed:
  - Dialyzer warnings

## v1.1.0

- Merged a ton of of old and neglected pull requests. Thanks to
  patient contributors:
  - Emil Falk
  - Evgeny Khramtsov
  - Kevin Wilson
  - Luis Rascão
  - Аверьянов Илья (savonarola on github)
  - ololoru
  - Giacomo Olgeni

- Removed rebar binary, made everything a bit more rebar3 & mix
  friendly.

## v1.0.8

- Fixed include directive to work with rebar 2.5.1. Thanks to Feng Hao
  for the patch.

## v1.0.7

- If an eredis_sub_client needs to reconnect to Redis, the controlling
  process is now notified with the message `{eredis_reconnect_attempt,
  Pid}`. If the reconnection attempt fails, the message is
  `{eredis_reconnect_failed, Pid, Reason}`. Thanks to Piotr Nosek for
  the patch.

- No more deprecation warnings of the `queue` type on OTP 17. Thanks
  to Daniel Kempkens for the patch.

- Various spec fixes. Thanks to Hernan Rivas Acosta and Anton Kalyaev.

## v1.0.6

- If the connection to Redis is lost, requests in progress will
  receive `{error, tcp_closed}` instead of the `gen_server:call`
  timing out. Thanks to Seth Falcon for the patch.

## v1.0.5

- Added support for not selecting any specific database. Thanks to
  Mikl Kurkov for the patch.

## v1.0.4

- Added `eredis:q_noreply/2` which sends a fire-and-forget request to
  Redis. Thanks to Ransom Richardson for the patch.

- Various type annotation improvements, typo fixes and robustness
  improvements. Thanks to Michael Gregson, Matthew Conway and Ransom
  Richardson.

## v1.0.3

- Fixed bug in eredis_sub where when the connection to Redis was lost,
  the socket would not be set into {active, once} on reconnect. Thanks
  to georgeye for the patch.

## v1.0.2

- Fixed bug in eredis_sub where the socket was incorrectly set to
  `{active, once}` twice. At large volumes of messages, this resulted
  in too many messages from the socket and we would be unable to keep
  up. Thanks to pmembrey for reporting.

## v1.0

- Support added for pubsub thanks to Dave Peticolas
  (jdavisp3). Implemented in `eredis_sub` and `eredis_sub_client` is a
  subscriber that will forward messages from Redis to an Erlang
  process with flow control. The user can configure to either drop
  messages or crash the driver if a certain queue size inside the
  driver is reached.

- Fixed error handling when eredis starts up and Redis is still
  loading the dataset into memory.

## v0.7.0

- Support added for pipelining requests, which allows batching
  multiple requests in a single call to eredis. Thanks to Dave
  Peticolas (jdavisp3) for the implementation.

## v0.6.0

- Support added for transactions, by Dave Peticolas (jdavisp3) who implemented
  parsing of nested multibulks.

## v0.5.0

- Configurable reconnect sleep time, by Valentino Volonghi (dialtone)

- Support for using eredis as a poolboy worker, by Valentino Volonghi
  (dialtone)
