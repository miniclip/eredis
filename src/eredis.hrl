-type parser_state() :: status_continue | bulk_continue | multibulk_continue.

%% Continuation data is whatever data returned by any of the parse
%% functions. This is used to continue where we left off the next time
%% the user calls parse/2.
-type continuation_data() :: any().

%% Internal parser state. Is returned from parse/2 and must be
%% included on the next calls to parse/2.
-record(pstate, {
          state = undefined :: parser_state() | undefined,
          continuation_data :: continuation_data() | undefined
}).
-type pstate() :: #pstate{}.

-define(NL, "\r\n").

-define(SOCKET_OPTS, [binary, {active, once}, {packet, raw}, {reuseaddr, false},
                      {send_timeout, ?SEND_TIMEOUT},
                      {keepalive, true}]).

-define(TCP_SOCKET_OPTS, ?SOCKET_OPTS).
-define(SSL_SOCKET_OPTS, ?SOCKET_OPTS).

-define(RECV_TIMEOUT, 5000).
-define(SEND_TIMEOUT, 5000).
