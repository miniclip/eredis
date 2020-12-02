%%
%% Erlang PubSub Redis client
%%
-module(eredis_sub).
-include("eredis.hrl").
-include("eredis_defaults.hrl").

-export([start_link/0, start_link/1, start_link/3, start_link/4, start_link/6, start_link/7,
         stop/1, controlling_process/1, controlling_process/2, controlling_process/3,
         ack_message/1, subscribe/2, unsubscribe/2, channels/1]).

-export([psubscribe/2,punsubscribe/2]).

-ignore_xref(start_link/0).
-ignore_xref(start_link/1).
-ignore_xref(start_link/3).
-ignore_xref(start_link/4).
-ignore_xref(start_link/6).
-ignore_xref(start_link/7).
-ignore_xref(stop/1).
-ignore_xref(controlling_process/1).
-ignore_xref(controlling_process/2).
-ignore_xref(controlling_process/3).
-ignore_xref(ack_message/1).
-ignore_xref(subscribe/2).
-ignore_xref(unsubscribe/2).
-ignore_xref(channels/1).
-ignore_xref(psubscribe/2).
-ignore_xref(punsubscribe/2).

-ifdef(TEST).
-export([receiver/1, sub_example/0, pub_example/0]).

-export([psub_example/0,ppub_example/0]).

-ignore_xref(sub_example/0).
-ignore_xref(pub_example/0).
-ignore_xref(psub_example/0).
-ignore_xref(ppub_example/0).
-endif.

-define(DEFAULT_MAX_QUEUE_SIZE, infinity).
-define(DEFAULT_QUEUE_BEHAVIOUR, drop).

-type sub_option() ::
        eredis:option() |
        {max_queue_size, non_neg_integer() | infinity} |
        {queue_behaviour, drop | exit}.
-export_type([sub_option/0]).

-type sub_args() :: [sub_option()].
-export_type([sub_args/0]).

-type channel() :: binary().
-export_type([channel/0]).

-type eredis_queue() :: queue:queue().
-export_type([eredis_queue/0]).

%%
%% PUBLIC API
%%

start_link() ->
    start_link([]).

start_link(Host, Port, Password) ->
    start_link([{host, Host},
                {port, Port},
                {password, Password}]).

start_link(Transport, Host, Port, Password) ->
    start_link([{transport, Transport},
                {host, Host},
                {port, Port},
                {password, Password}]).

start_link(Host, Port, Password, ReconnectSleep,
           MaxQueueSize, QueueBehaviour) ->
    start_link([{host, Host},
                {port, Port},
                {password, Password},
                {reconnect_sleep, ReconnectSleep},
                {max_queue_size, MaxQueueSize},
                {queue_behaviour, QueueBehaviour}]).

start_link(Transport, Host, Port, Password, ReconnectSleep,
           MaxQueueSize, QueueBehaviour)
  when is_atom(Transport) andalso
       is_list(Host) andalso
       is_integer(Port) andalso
       is_list(Password) andalso
       (is_integer(ReconnectSleep) orelse ReconnectSleep =:= no_reconnect) andalso
       (is_integer(MaxQueueSize) orelse MaxQueueSize =:= infinity) andalso
       (QueueBehaviour =:= drop orelse QueueBehaviour =:= exit) ->

    eredis_sub_client:start_link(Transport, Host, Port, Password, ReconnectSleep,
                                 MaxQueueSize, QueueBehaviour).

%% @doc Callback for starting from poolboy
-spec start_link(sub_args()) -> {ok, Pid::pid()} | {error, Reason::term()}.
start_link(Args) ->
    Transport      = proplists:get_value(transport, Args, ?DEFAULT_TRANSPORT),
    Host           = proplists:get_value(host, Args, ?DEFAULT_HOST),
    Port           = proplists:get_value(port, Args, ?DEFAULT_PORT(Transport)),
    Password       = proplists:get_value(password, Args, ?DEFAULT_PASSWORD),
    ReconnectSleep = proplists:get_value(reconnect_sleep, Args, ?DEFAULT_RECONNECT_SLEEP),
    MaxQueueSize   = proplists:get_value(max_queue_size, Args, ?DEFAULT_MAX_QUEUE_SIZE),
    QueueBehaviour = proplists:get_value(queue_behaviour, Args, ?DEFAULT_QUEUE_BEHAVIOUR),
    start_link(Transport, Host, Port, Password, ReconnectSleep,
               MaxQueueSize, QueueBehaviour).

stop(Pid) ->
    eredis_sub_client:stop(Pid).

-spec controlling_process(Client::pid()) -> ok.
%% @doc Make the calling process the controlling process. The
%% controlling process received pubsub-related messages, of which
%% there are three kinds. In each message, the pid refers to the
%% eredis client process.
%%
%%   {message, Channel::binary(), Message::binary(), pid()}
%%     This is sent for each pubsub message received by the client.
%%
%%   {pmessage, Pattern::binary(), Channel::binary(), Message::binary(), pid()}
%%     This is sent for each pattern pubsub message received by the client.
%%
%%   {dropped, NumMessages::integer(), pid()}
%%     If the queue reaches the max size as specified in start_link
%%     and the behaviour is to drop messages, this message is sent when
%%     the queue is flushed.
%%
%%   {subscribed, Channel::binary(), pid()}
%%     When using eredis_sub:subscribe(pid()), this message will be
%%     sent for each channel Redis aknowledges the subscription. The
%%     opposite, 'unsubscribed' is sent when Redis aknowledges removal
%%     of a subscription.
%%
%%   {eredis_disconnected, pid()}
%%     This is sent when the eredis client is disconnected from redis.
%%
%%   {eredis_connected, pid()}
%%     This is sent when the eredis client reconnects to redis after
%%     an existing connection was disconnected.
%%
%% Any message of the form {message, _, _, _} must be acknowledged
%% before any subsequent message of the same form is sent. This
%% prevents the controlling process from being overrun with redis
%% pubsub messages. See ack_message/1.
controlling_process(Client) ->
    controlling_process(Client, self()).

-spec controlling_process(Client::pid(), Pid::pid()) -> ok.
%% @doc Make the given process (pid) the controlling process.
controlling_process(Client, Pid) ->
    controlling_process(Client, Pid, ?TIMEOUT).

%% @doc Make the given process (pid) the controlling process subscriber
%% with the given Timeout.
controlling_process(Client, Pid, Timeout) ->
    gen_server:call(Client, {controlling_process, Pid}, Timeout).

-spec ack_message(Client::pid()) -> ok.
%% @doc acknowledge the receipt of a pubsub message. each pubsub
%% message must be acknowledged before the next one is received
ack_message(Client) ->
    gen_server:cast(Client, {ack_message, self()}).

%% @doc Subscribe to the given channels. Returns immediately. The
%% result will be delivered to the controlling process as any other
%% message. Delivers {subscribed, Channel::binary(), pid()}
-spec subscribe(pid(), [channel()]) -> ok.
subscribe(Client, Channels) ->
    gen_server:cast(Client, {subscribe, self(), Channels}).

%% @doc Pattern subscribe to the given channels. Returns immediately. The
%% result will be delivered to the controlling process as any other
%% message. Delivers {subscribed, Channel::binary(), pid()}
-spec psubscribe(pid(), [channel()]) -> ok.
psubscribe(Client, Channels) ->
    gen_server:cast(Client, {psubscribe, self(), Channels}).

unsubscribe(Client, Channels) ->
    gen_server:cast(Client, {unsubscribe, self(), Channels}).

punsubscribe(Client, Channels) ->
    gen_server:cast(Client, {punsubscribe, self(), Channels}).

%% @doc Returns the channels the given client is currently
%% subscribing to. Note: this list is based on the channels at startup
%% and any channel added during runtime. It might not immediately
%% reflect the channels Redis thinks the client is subscribed to.
channels(Client) ->
    gen_server:call(Client, get_channels).

%%
%% STUFF FOR TRYING OUT PUBSUB
%%

-ifdef(TEST).
receiver(Sub) ->
    receive
        Msg ->
            io:format("received ~p~n", [Msg]),
            ack_message(Sub),
            ?MODULE:receiver(Sub)
    end.

sub_example() ->
    {ok, Sub} = start_link(),
    Receiver = spawn_link(fun () ->
                                  controlling_process(Sub),
                                  subscribe(Sub, [<<"foo">>]),
                                  receiver(Sub)
                          end),
    {Sub, Receiver}.

psub_example() ->
    {ok, Sub} = start_link(),
    Receiver = spawn_link(fun () ->
                                  controlling_process(Sub),
                                  psubscribe(Sub, [<<"foo*">>]),
                                  receiver(Sub)
                          end),
    {Sub, Receiver}.

pub_example() ->
    {ok, P} = eredis:start_link(),
    {ok, <<_/binary>>} = eredis:q(P, ["PUBLISH", "foo", "bar"]),
    eredis_client:stop(P).

ppub_example() ->
    {ok, P} = eredis:start_link(),
    {ok, <<_/binary>>} = eredis:q(P, ["PUBLISH", "foo123", "bar"]),
    eredis_client:stop(P).
-endif.

