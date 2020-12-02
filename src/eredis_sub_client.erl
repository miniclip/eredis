%% @hidden
%%
%% eredis_pubsub_client
%%
%% This client implements a subscriber to a Redis pubsub channel. It
%% is implemented in the same way as eredis_client, except channel
%% messages are streamed to the controlling process. Messages are
%% queued and delivered when the client acknowledges receipt.
%%
%% There is one consuming process per eredis_sub_client.
-module(eredis_sub_client).
-behaviour(gen_server).
-include("eredis.hrl").
-include("eredis_defaults.hrl").

-record(state, {
          transport :: eredis:transport(),
          host :: undefined | eredis:host(),
          port :: undefined | 0..65535,
          password :: undefined | binary(),
          reconnect_sleep :: undefined | eredis:reconnect_sleep(),

          transport_module :: undefined | module(),
          socket :: undefined | gen_tcp:socket() | ssl:sslsocket(),
          transport_data_tag :: atom(),
          transport_closure_tag :: atom(),
          transport_error_tag :: atom(),

          parser_state :: undefined | #pstate{},

          %% Channels we should subscribe to
          channels = [] :: [eredis_sub:channel()],

          % The process we send pubsub and connection state messages to.
          controlling_process :: undefined | {reference(), pid()},

          % This is the queue of messages to send to the controlling
          % process.
          msg_queue :: eredis_sub:eredis_queue(),

          %% When the queue reaches this size, either drop all
          %% messages or exit.
          max_queue_size :: non_neg_integer() | infinity,
          queue_behaviour :: drop | exit,

          % The msg_state keeps track of whether we are waiting
          % for the controlling process to acknowledge the last
          % message.
          msg_state = need_ack :: ready | need_ack
}).

%% API
-export([start_link/7, stop/1]).

-ifdef(TEST).
-export([get_controlling_process/1]).
-export([get_socket/1]).

-ignore_xref(get_controlling_process/1).
-ignore_xref(get_socket/1).
-endif.

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%
%% API
%%

-spec start_link(Transport::eredis:transport(),
                 Host::eredis:host(),
                 Port::0..65535,
                 Password::string(),
                 ReconnectSleep::eredis:reconnect_sleep(),
                 MaxQueueSize::non_neg_integer() | infinity,
                 QueueBehaviour::drop | exit) ->
                        {ok, Pid::pid()} | {error, Reason::term()}.
start_link(Transport, Host, Port, Password, ReconnectSleep, MaxQueueSize, QueueBehaviour) ->
    Args = [Transport, Host, Port, Password, ReconnectSleep, MaxQueueSize, QueueBehaviour],
    gen_server:start_link(?MODULE, Args, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Transport, Host, Port, Password, ReconnectSleep, MaxQueueSize, QueueBehaviour]) ->
    State = #state{transport = Transport,
                   host            = Host,
                   port            = Port,
                   password        = list_to_binary(Password),
                   reconnect_sleep = ReconnectSleep,
                   channels        = [],
                   parser_state    = eredis_parser:init(),
                   msg_queue       = queue:new(),
                   max_queue_size  = MaxQueueSize,
                   queue_behaviour = QueueBehaviour},

    case connect(State) of
        {ok, NewState} ->
            ok = set_socket_opts([{active, once}], NewState),
            {ok, NewState};
        {error, Reason} ->
            {stop, Reason}
    end.

%% Set the controlling process. All messages on all channels are directed here.
handle_call({controlling_process, Pid}, _From, State) ->
    case State#state.controlling_process of
        undefined ->
            ok;
        {OldRef, _OldPid} ->
            erlang:demonitor(OldRef)
    end,
    Ref = erlang:monitor(process, Pid),
    {reply, ok, State#state{controlling_process={Ref, Pid}, msg_state = ready}};
handle_call(get_channels, _From, State) ->
    {reply, {ok, State#state.channels}, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

%% Controlling process acks, but we have no connection. When the
%% connection comes back up, we should be ready to forward a message
%% again.
handle_cast({ack_message, Pid},
            #state{controlling_process={_, Pid}, socket = undefined} = State) ->
    {noreply, State#state{msg_state = ready}};
%% Controlling process acknowledges receipt of previous message. Send
%% the next if there is any messages queued or ask for more on the
%% socket.
handle_cast({ack_message, Pid},
            #state{controlling_process={_, Pid}} = State) ->
    NewState = case queue:out(State#state.msg_queue) of
                   {empty, _Queue} ->
                       State#state{msg_state = ready};
                   {{value, Msg}, Queue} ->
                       send_to_controller(Msg, State),
                       State#state{msg_queue = Queue, msg_state = need_ack}
               end,
    {noreply, NewState};
handle_cast({subscribe, Pid, Channels}, #state{controlling_process = {_, Pid}} = State) ->
    Command = eredis:create_multibulk(["SUBSCRIBE" | Channels]),
    ok = (State#state.transport_module):send(State#state.socket, Command),
    NewChannels = add_channels(Channels, State#state.channels),
    {noreply, State#state{channels = NewChannels}};
handle_cast({psubscribe, Pid, Channels}, #state{controlling_process = {_, Pid}} = State) ->
    Command = eredis:create_multibulk(["PSUBSCRIBE" | Channels]),
    ok = (State#state.transport_module):send(State#state.socket, Command),
    NewChannels = add_channels(Channels, State#state.channels),
    {noreply, State#state{channels = NewChannels}};
handle_cast({unsubscribe, Pid, Channels}, #state{controlling_process = {_, Pid}} = State) ->
    Command = eredis:create_multibulk(["UNSUBSCRIBE" | Channels]),
    ok = (State#state.transport_module):send(State#state.socket, Command),
    NewChannels = remove_channels(Channels, State#state.channels),
    {noreply, State#state{channels = NewChannels}};
handle_cast({punsubscribe, Pid, Channels}, #state{controlling_process = {_, Pid}} = State) ->
    Command = eredis:create_multibulk(["PUNSUBSCRIBE" | Channels]),
    ok = (State#state.transport_module):send(State#state.socket, Command),
    NewChannels = remove_channels(Channels, State#state.channels),
    {noreply, State#state{channels = NewChannels}};
handle_cast({ack_message, _}, State) ->
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Receive data from socket, see handle_response/2
handle_info({Tag, _Socket, Bs}, #state{transport_data_tag = Tag} = State) ->
    ok = set_socket_opts([{active, once}], State),

    NewState = handle_response(Bs, State),
    case queue:len(NewState#state.msg_queue) > NewState#state.max_queue_size of
        true ->
            case State#state.queue_behaviour of
                drop ->
                    Msg = {dropped, queue:len(NewState#state.msg_queue)},
                    send_to_controller(Msg, NewState),
                    {noreply, NewState#state{msg_queue = queue:new()}};
                exit ->
                    {stop, max_queue_size, State}
            end;
        false ->
            {noreply, NewState}
    end;
handle_info({Tag, _Socket, _Reason}, #state{transport_error_tag = Tag} = State) ->
    %% This will be followed by a close
    {noreply, State};
%% Socket got closed, for example by Redis terminating idle
%% clients. If desired, spawn of a new process which will try to reconnect and
%% notify us when Redis is ready. In the meantime, we can respond with
%% an error message to all our clients.
handle_info({Tag, _Socket}, #state{transport_closure_tag = Tag, reconnect_sleep = no_reconnect} = State) ->
    %% If we aren't going to reconnect, then there is nothing else for this process to do.
    {stop, normal, State#state{socket = undefined}};
handle_info({Tag, _Socket}, #state{transport_closure_tag = Tag} = State) ->
    Self = self(),
    send_to_controller({eredis_disconnected, Self}, State),
    spawn(fun() -> reconnect_loop(Self, State) end),

    %% Throw away the socket. The absence of a socket is used to
    %% signal we are "down"; discard possibly patrially parsed data
    {noreply, State#state{socket = undefined, parser_state = eredis_parser:init()}};
%% Controller might want to be notified about every reconnect attempt
handle_info(reconnect_attempt, State) ->
    send_to_controller({eredis_reconnect_attempt, self()}, State),
    {noreply, State};
%% Controller might want to be notified about every reconnect failure and reason
handle_info({reconnect_failed, Reason}, State) ->
    send_to_controller({eredis_reconnect_failed, self(),
                        {error, {connection_error, Reason}}}, State),
    {noreply, State};
%% Redis is ready to accept requests, the given Socket is a socket
%% already connected and authenticated.
handle_info({connection_ready, Socket}, #state{socket = undefined} = State) ->
    send_to_controller({eredis_connected, self()}, State),
    NewState = State#state{socket = Socket},
    ok = set_socket_opts([{active, once}], NewState),
    {noreply, NewState};
%% Our controlling process is down.
handle_info({'DOWN', Ref, process, Pid, _Reason},
            #state{controlling_process={Ref, Pid}} = State) ->
    {stop, shutdown, State#state{controlling_process=undefined,
                                 msg_state=ready,
                                 msg_queue=queue:new()}};
%% eredis can be used in Poolboy, but it requires to support a simple API
%% that Poolboy uses to manage the connections.
handle_info(stop, State) ->
    {stop, shutdown, State};
handle_info(_Info, State) ->
    {stop, {unhandled_message, _Info}, State}.

terminate(_Reason, State) ->
    case State#state.socket of
        undefined -> ok;
        Socket    -> (State#state.transport_module):close(Socket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-ifdef(TEST).
get_controlling_process(#state{ controlling_process = {_, Pid} }) -> Pid.
get_socket(#state{ socket = Socket }) -> Socket.
-endif.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec remove_channels([binary()], [binary()]) -> [binary()].
remove_channels(Channels, OldChannels) ->
    lists:foldl(fun lists:delete/2, OldChannels, Channels).

-spec add_channels([binary()], [binary()]) -> [binary()].
add_channels(Channels, OldChannels) ->
    lists:foldl(fun(C, Cs) ->
        case lists:member(C, Cs) of
            true ->
                Cs;
            false ->
                [C|Cs]
        end
    end, OldChannels, Channels).

-spec handle_response(Data::binary(), State::#state{}) -> NewState::#state{}.
%% Handle the response coming from Redis. This should only be
%% channel messages that we should forward to the controlling process
%% or queue if the previous message has not been acked. If there are
%% more than a single response in the data we got, queue the responses
%% and serve them up when the controlling process is ready
handle_response(Data, #state{parser_state = ParserState} = State) ->
    case eredis_parser:parse(ParserState, Data) of
        {ReturnCode, Value, NewParserState} ->
            reply({ReturnCode, Value},
                  State#state{parser_state=NewParserState});
        {ReturnCode, Value, Rest, NewParserState} ->
            NewState = reply({ReturnCode, Value},
                             State#state{parser_state=NewParserState}),
            handle_response(Rest, NewState);
        {continue, NewParserState} ->
            State#state{parser_state = NewParserState}
    end.

%% Sends a reply to the controlling process if the process has
%% acknowledged the previous process, otherwise the message is queued
%% for later delivery.
reply({ok, [<<"message">>, Channel, Message]}, State) ->
    queue_or_send({message, Channel, Message, self()}, State);
reply({ok, [<<"pmessage">>, Pattern, Channel, Message]}, State) ->
    queue_or_send({pmessage, Pattern, Channel, Message, self()}, State);
reply({ok, [<<"subscribe">>, Channel, _]}, State) ->
    queue_or_send({subscribed, Channel, self()}, State);
reply({ok, [<<"psubscribe">>, Channel, _]}, State) ->
    queue_or_send({subscribed, Channel, self()}, State);
reply({ok, [<<"unsubscribe">>, Channel, _]}, State) ->
    queue_or_send({unsubscribed, Channel, self()}, State);
reply({ok, [<<"punsubscribe">>, Channel, _]}, State) ->
    queue_or_send({unsubscribed, Channel, self()}, State);
reply({ReturnCode, Value}, State) ->
    throw({unexpected_response_from_redis, ReturnCode, Value, State}).

queue_or_send(Msg, State) ->
    case State#state.msg_state of
        need_ack ->
            MsgQueue = queue:in(Msg, State#state.msg_queue),
            State#state{msg_queue = MsgQueue};
        ready ->
            send_to_controller(Msg, State),
            State#state{msg_state = need_ack}
    end.

%% Helper for connecting to Redis. These commands are
%% synchronous and if Redis returns something we don't expect, we
%% crash. Returns {ok, State} or {error, Reason}.
connect(State) ->
    {Module, ConnectOpts,
     DataTag, ClosureTag, ErrorTag} = transport_params(State),

    case Module:connect(State#state.host, State#state.port, ConnectOpts, infinity) of
        {ok, Socket} ->
            NewState =
                State#state{transport_module = Module,
                            socket = Socket,
                            transport_data_tag = DataTag,
                            transport_closure_tag = ClosureTag,
                            transport_error_tag = ErrorTag},

            case authenticate(NewState) of
                ok ->
                    {ok, NewState};
                {error, Reason} ->
                    {error, {authentication_error, Reason}}
            end;
        {error, Reason} ->
            {error, {connection_error, Reason}}
    end.

transport_params(State) when State#state.transport =:= tcp ->
    {gen_tcp, ?TCP_SOCKET_OPTS,
     tcp, tcp_closed, tcp_error};
transport_params(State) when State#state.transport =:= ssl ->
    Host = State#state.host,
    ConnectOpts = ?SSL_SOCKET_OPTS ++ tls_certificate_check:options(Host),
    {ssl, ConnectOpts,
     ssl, ssl_closed, ssl_error}.

authenticate(State)
  when State#state.password =:= <<>> ->
    ok;
authenticate(State) ->
    Password = State#state.password,
    do_sync_command(["AUTH", " \"", Password, "\"\r\n"], State).

%% Executes the given command synchronously, expects Redis to
%% return "+OK\r\n", otherwise it will fail.
do_sync_command(Command, State) ->
    ok = set_socket_opts([{active, false}], State),
    TransportModule = State#state.transport_module,
    Socket = State#state.socket,
    case TransportModule:send(Socket, Command) of
        ok ->
            %% Hope there's nothing else coming down on the socket..
            case TransportModule:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, <<"+OK\r\n">>} ->
                    ok = set_socket_opts([{active, once}], State),
                    ok;
                Other ->
                    {error, {unexpected_data, Other}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

set_socket_opts(Opts, State) ->
    case State#state.transport_module of
        gen_tcp ->
            inet:setopts(State#state.socket, Opts);
        ssl ->
            ssl:setopts(State#state.socket, Opts)
    end.

%% Loop until a connection can be established, this includes
%% successfully issuing the auth and select calls. When we have a
%% connection, give the socket to the redis client.
reconnect_loop(Client, #state{reconnect_sleep=ReconnectSleep}=State) ->
    Client ! reconnect_attempt,
    case catch(connect(State)) of
        {ok, #state{transport_module = TransportModule, socket = Socket}} ->
            TransportModule:controlling_process(Socket, Client),
            Client ! {connection_ready, Socket};
        {error, Reason} ->
            Client ! {reconnect_failed, Reason},
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State);
        %% Something bad happened when connecting, like Redis might be
        %% loading the dataset and we got something other than 'OK' in
        %% auth or select
        _ ->
            timer:sleep(ReconnectSleep),
            reconnect_loop(Client, State)
    end.

send_to_controller(_Msg, #state{controlling_process=undefined}) ->
    ok;
send_to_controller(Msg, #state{controlling_process={_Ref, Pid}}) ->
    Pid ! Msg.
