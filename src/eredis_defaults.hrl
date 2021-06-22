%% Default timeout for calls to the client gen_server
%% Specified in http://www.erlang.org/doc/man/gen_server.html#call-3
-define(TIMEOUT, 5000).

-define(DEFAULT_TRANSPORT, tcp).
-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_PORT(Transport), (case (Transport) of tcp -> 6379; ssl -> 6380 end)).
-define(DEFAULT_PASSWORD, "").
-define(DEFAULT_RECONNECT_SLEEP, 100).
