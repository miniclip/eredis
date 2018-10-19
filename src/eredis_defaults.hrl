%% Default timeout for calls to the client gen_server
%% Specified in http://www.erlang.org/doc/man/gen_server.html#call-3
-define(TIMEOUT, 5000).

-define(DEFAULT_TRANSPORT, tcp).
-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_PORT(Transport), (case (Transport) of tcp -> ?DEFAULT_TCP_PORT; ssl -> ?DEFAULT_SSL_PORT end)).
-define(DEFAULT_TCP_PORT, 6379).
-define(DEFAULT_SSL_PORT, 6380).
-define(DEFAULT_DATABASE, 0).
-define(DEFAULT_PASSWORD, "").
-define(DEFAULT_RECONNECT_SLEEP, 100).
-define(DEFAULT_CONNECT_TIMEOUT, ?TIMEOUT).
