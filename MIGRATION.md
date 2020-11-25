# Migration Plan
Whenever there's an interface BREAKING CHANGE (a change in the project's major version),
required migration instructions will be detailed in this file.

## From [2.x] to [3.x]

### Update

- your code to depend on types from `eredis:` and `lhttpc_client:` and not (imported)
`eredis.hrl` and `eredis_sub.hrl` (a simple `dialyzer` procedure should put into evidence what is
mis-specified)

### Remove

- your code's import of `eredis.hrl`
- your code's import of `eredis_sub.hrl`

## From [1.x] to [2.x]

### Update
- calls to `:q_async/2` and `q_async/3` and matching of their asynchronous replies:
```
% where before you had:
eredis:q_async(Client, Command)
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
