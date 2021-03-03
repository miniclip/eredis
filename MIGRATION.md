# Migration guide

Whenever there's an interface breaking change (a change in the project's major version),
required migration instructions will be detailed in this file.

## From [2.x] to [3.x]

### Update

- your code to depend on types from `eredis:` and not
(imported) `eredis.hrl` (a simple `dialyzer` procedure
should put into evidence what is mis-specified)
- where you're importing the `eredis.hrl` header and using type `X()`,
remove the import and use `eredis:X()` instead; do this for types
`parser_state`, `continuation_data`, and `pstate`
- your code to not depend on `eredis.hrl` macros
`NL`, `SOCKET_OPTS`, `TCP_SOCKET_OPTS`, `SSL_SOCKET_OPTS`,
`RECV_TIMEOUT` or `SEND_TIMEOUT`; copy their content from
`src/eredis.hrl`

### Remove

- your code's import of `eredis.hrl`
- your code's import of `eredis_sub.hrl`

## From [1.x] to [2.x]

### Update

- calls to `:q_async/2` and `q_async/3` and matching of their asynchronous
replies:

```erlang
% where before you had:
eredis:q_async(Client, Command) ->
    % [...]

handle_info({response, Reply}, State) ->
    % [...]

% now you should have:
{await, ReplyTag} = eredis:q_async(Client, Command),
NewState = State#state{ reply_tag = ReplyTag }.
    % [...]

handle_info({ReplyTag, Reply}, State) when ReplyTag =:= State#state.reply_tag ->
    % [...]
```
