%% @hidden
%%
%% eredis_client
%%
%% The client is implemented as a gen_server which keeps one socket
%% open to a single Redis instance. Users call us using the API in
%% eredis.erl.
%%
%% The client works like this:
%%  * When starting up, we connect to Redis with the given connection
%%     information, or fail.
%%  * Users calls us using gen_server:call, we send the request to Redis,
%%    add the calling process at the end of the queue and reply with
%%    noreply. We are then free to handle new requests and may reply to
%%    the user later.
%%  * We receive data on the socket, we parse the response and reply to
%%    the client at the front of the queue. If the parser does not have
%%    enough data to parse the complete response, we will wait for more
%%    data to arrive.
%%  * For pipeline commands, we include the number of responses we are
%%    waiting for in each element of the queue. Responses are queued until
%%    we have all the responses we need and then reply with all of them.
%%
-module(eredis_client).
-behaviour(gen_server).
-include("eredis.hrl").

%% API
-export([start_link/7, stop/1]).

%% proc_lib callbacks
-export([init/2]). -ignore_xref([init/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-export([get_socket/1]).

-ignore_xref(get_socket/1).
-endif.

-record(state, {
          transport :: eredis:transport(),
          host :: string() | {local,term()} | undefined,
          port :: integer() | undefined,
          password :: binary() | undefined,
          database :: binary() | undefined,
          reconnect_sleep :: eredis:reconnect_sleep() | undefined,
          connect_timeout :: non_neg_integer() | undefined,

          transport_module :: module() | undefined,
          socket :: gen_tcp:socket() | ssl:sslsocket() | undefined,
          transport_data_tag :: atom(),
          transport_closure_tag :: atom(),
          transport_error_tag :: atom(),

          parser_state :: #pstate{} | undefined,
          queue :: eredis_sub:eredis_queue() | undefined
}).

%%
%% API
%%

-spec start_link(Transport::eredis:transport(),
                 Host::list(),
                 Port::integer(),
                 Database::integer() | undefined,
                 Password::string(),
                 ReconnectSleep::eredis:reconnect_sleep(),
                 ConnectTimeout::non_neg_integer() | undefined) ->
                        {ok, Pid::pid()} | {error, Reason::term()}.
start_link(Transport, Host, Port, Database, Password, ReconnectSleep, ConnectTimeout) ->
    Args = [Transport, Host, Port, Database, Password, ReconnectSleep, ConnectTimeout],
    proc_lib:start_link(?MODULE, init, [self(), Args]).

stop(Pid) ->
    gen_server:call(Pid, stop).

-ifdef(TEST).
get_socket(Pid) ->
    State = sys:get_state(Pid),
    State#state.socket.
-endif.

%%====================================================================
%% proc_lib callbacks
%%====================================================================

init(ParentPid, [Transport, Host, Port, Database, Password, ReconnectSleep, ConnectTimeout])
  when Transport =:= tcp;
       (Transport =:= ssl andalso is_list(Host)) % UNIX socket hosts not supported with ssl
       ->
    State = #state{transport = Transport,
                   host = Host,
                   port = Port,
                   database = read_database(Database),
                   password = list_to_binary(Password),
                   reconnect_sleep = ReconnectSleep,
                   connect_timeout = ConnectTimeout,

                   parser_state = eredis_parser:init(),
                   queue = queue:new()},

    case ReconnectSleep =:= no_reconnect of
        true ->
            connect_on_init(ParentPid,State);
        false ->
            proc_lib:init_ack(ParentPid, {ok, self()}),
            self() ! connect,
            gen_server:enter_loop(?MODULE, [], State)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_) ->
    ignore.

handle_call({request, Req}, From, State) ->
    do_request(Req, From, State);
handle_call({pipeline, Pipeline}, From, State) ->
    do_pipeline(Pipeline, From, State);
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, unknown_request, State}.

handle_cast({request, Req}, State) ->
    case do_request(Req, undefined, State) of
        {reply, _Reply, State1} ->
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;
handle_cast({request, Req, From}, State) ->
    case do_request(Req, From, State) of
        {reply, Reply, State1} ->
            safe_reply(From, Reply),
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;
handle_cast({pipeline, Req}, State) ->
    case do_pipeline(Req, undefined, State) of
        {reply, _Reply, State1} ->
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;
handle_cast({pipeline, Req, From}, State) ->
    case do_pipeline(Req, From, State) of
        {reply, Reply, State1} ->
            safe_reply(From, Reply),
            {noreply, State1};
        {noreply, State1} ->
            {noreply, State1}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Tag, Socket, Bs}, #state{transport_data_tag = Tag, socket = Socket} = State) ->
    _ = set_socket_opts([{active, once}], State),
    {noreply, handle_response(Bs, State)};
handle_info({Tag, Socket, Reason}, #state{transport_error_tag = Tag, socket = Socket} = State) ->
    TransportModule = State#state.transport_module,
    _ = TransportModule:close(Socket),
    handle_socket_removal(Reason, State);
handle_info({Tag, Socket}, #state{transport_closure_tag = Tag, socket = Socket} = State) ->
    handle_socket_removal(closed, State);
handle_info(connect, #state{socket = undefined} = State) ->
    handle_connect(State);
handle_info(stop, State) ->
    {stop, shutdown, State};
handle_info(_Info, State) ->
    {stop, {unhandled_message, _Info}, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

connect_on_init(ParentPid, State) ->
    case handle_connect(State) of
        {noreply, NewState} ->
            proc_lib:init_ack(ParentPid, {ok, self()}),
            gen_server:enter_loop(?MODULE, [], NewState);
        {stop, {connect, Reason}, _NewState} ->
            proc_lib:init_ack(ParentPid, {error, Reason}),
            unlink(ParentPid),
            exit(normal)
    end.

handle_connect(State) ->
    case connect(State) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, Reason} when State#state.reconnect_sleep =:= no_reconnect ->
            {stop, {connect, Reason}, State};
        {error, Reason} ->
            error_logger:error_msg("eredis (~p:~p): ~p",
                                   [State#state.host, State#state.port, Reason]),
            erlang:send_after(State#state.reconnect_sleep, self(), connect),
            {noreply, State}
    end.

-spec do_request(Req::iolist(), From::undefined | pid(), #state{}) ->
                        {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the given request to redis. If we do not have a
%% connection, returns error.
do_request(_Req, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_request(Req, From, State) ->
    case (State#state.transport_module):send(State#state.socket, Req) of
        ok ->
            NewQueue = queue:in({1, From}, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec do_pipeline(Pipeline::eredis:pipeline(), From::undefined | pid() | {pid(),reference()}, #state{}) ->
                         {noreply, #state{}} | {reply, Reply::any(), #state{}}.
%% @doc: Sends the entire pipeline to redis. If we do not have a
%% connection, returns error.
do_pipeline(_Pipeline, _From, #state{socket = undefined} = State) ->
    {reply, {error, no_connection}, State};

do_pipeline(Pipeline, From, State) ->
    case (State#state.transport_module):send(State#state.socket, Pipeline) of
        ok ->
            NewQueue = queue:in({length(Pipeline), From, []}, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec handle_response(Data::binary(), State::#state{}) -> NewState::#state{}.
%% @doc: Handle the response coming from Redis. This includes parsing
%% and replying to the correct client, handling partial responses,
%% handling too much data and handling continuations.
handle_response(Data, #state{parser_state = ParserState,
                             queue = Queue} = State) ->

    case eredis_parser:parse(ParserState, Data) of
        %% Got complete response, return value to client
        {ReturnCode, Value, NewParserState} ->
            NewQueue = reply({ReturnCode, Value}, Queue),
            State#state{parser_state = NewParserState,
                        queue = NewQueue};

        %% Got complete response, with extra data, reply to client and
        %% recurse over the extra data
        {ReturnCode, Value, Rest, NewParserState} ->
            NewQueue = reply({ReturnCode, Value}, Queue),
            handle_response(Rest, State#state{parser_state = NewParserState,
                                              queue = NewQueue});

        %% Parser needs more data, the parser state now contains the
        %% continuation data and we will try calling parse again when
        %% we have more data
        {continue, NewParserState} ->
            State#state{parser_state = NewParserState}
    end.

%% @doc: Sends a value to the first client in queue. Returns the new
%% queue without this client. If we are still waiting for parts of a
%% pipelined request, push the reply to the the head of the queue and
%% wait for another reply from redis.
reply(Value, Queue) ->
    case queue:out(Queue) of
        {{value, {1, From}}, NewQueue} ->
            safe_reply(From, Value),
            NewQueue;
        {{value, {1, From, Replies}}, NewQueue} ->
            safe_reply(From, lists:reverse([Value | Replies])),
            NewQueue;
        {{value, {N, From, Replies}}, NewQueue} when N > 1 ->
            queue:in_r({N - 1, From, [Value | Replies]}, NewQueue);
        {empty, Queue} ->
            %% Oops
            error_logger:info_msg("eredis: Nothing in queue, but got value from parser~n"),
            exit(empty_queue)
    end.

%% @doc Send `Value' to each client in queue. Only useful for sending
%% an error message. Any in-progress reply data is ignored.
reply_all(Value, Queue) ->
    case queue:peek(Queue) of
        empty ->
            ok;
        {value, Item} ->
            safe_reply(receipient(Item), Value),
            reply_all(Value, queue:drop(Queue))
    end.

receipient({_, From}) ->
    From;
receipient({_, From, _}) ->
    From.

safe_reply(undefined, _Value) ->
    ok;
safe_reply(Pid, Value) when is_pid(Pid) ->
    safe_send(Pid, {response, Value});
safe_reply(From, Value) ->
    gen_server:reply(From, Value).

safe_send(Pid, Value) ->
    try erlang:send(Pid, Value)
    catch
        Err:Reason ->
            error_logger:info_msg("eredis: Failed to send message to ~p with reason ~p~n", [Pid, {Err, Reason}])
    end.

%% @doc: Helper for connecting to Redis, authenticating and selecting
%% the correct database. These commands are synchronous and if Redis
%% returns something we don't expect, we crash. Returns {ok, State} or
%% {SomeError, Reason}.
connect(State) ->
    {Module, Addr, Port, ConnectOpts,
     DataTag, ClosureTag, ErrorTag} = transport_params(State),

    case Module:connect(Addr, Port, ConnectOpts, State#state.connect_timeout) of
        {ok, Socket} ->
            NewState =
                State#state{transport_module = Module,
                            socket = Socket,
                            transport_data_tag = DataTag,
                            transport_closure_tag = ClosureTag,
                            transport_error_tag = ErrorTag},

            case authenticate(NewState) of
                ok ->
                    case select_database(NewState) of
                        ok ->
                            {ok, NewState};
                        {error, Reason} ->
                            close_and_flush_socket_messages(NewState),
                            {error, {select_error, Reason}}
                    end;
                {error, Reason} ->
                    close_and_flush_socket_messages(NewState),
                    {error, {authentication_error, Reason}}
            end;
        {error, Reason} ->
            {error, {connection_error, Reason}}
    end.

close_and_flush_socket_messages(State) when State#state.socket =/= undefined ->
    _ = (State#state.transport_module):close(State#state.socket),
    flush_socket_messages(State).

transport_params(State) when State#state.transport =:= tcp ->
    Host = State#state.host,
    {ok, {AFamily, Addr}} = get_addr(Host),
    Port =
        case AFamily of
            local -> 0;
            _ -> State#state.port
        end,
    {gen_tcp, Addr, Port, [AFamily | ?TCP_SOCKET_OPTS],
     tcp, tcp_closed, tcp_error};
transport_params(State) when State#state.transport =:= ssl ->
    Host = State#state.host,
    Port = State#state.port,
    ConnectOpts = ?SSL_SOCKET_OPTS ++ tls_certificate_check:options(Host),
    {ssl, Host, Port, ConnectOpts,
     ssl, ssl_closed, ssl_error}.

get_addr({local, Path}) ->
    {ok, {local, {local, Path}}};
get_addr(Hostname) ->
    case inet:parse_address(Hostname) of
        {ok, {_,_,_,_} = Addr} ->         {ok, {inet, Addr}};
        {ok, {_,_,_,_,_,_,_,_} = Addr} -> {ok, {inet6, Addr}};
        {error, einval} ->
            case inet:getaddr(Hostname, inet6) of
                 {error, _} ->
                     case inet:getaddr(Hostname, inet) of
                         {ok, Addr}-> {ok, {inet, Addr}};
                         {error, _} = Res -> Res
                     end;
                 {ok, Addr} -> {ok, {inet6, Addr}}
            end
    end.

select_database(State)
  when State#state.database =:= undefined;
       State#state.database =:= <<>> ->
    ok;
select_database(State) ->
    Database = State#state.database,
    do_sync_command(["SELECT", " ", Database, "\r\n"], State).

authenticate(State)
  when State#state.password =:= <<>> ->
    ok;
authenticate(State) ->
    Password = State#state.password,
    do_sync_command(["AUTH", " \"", Password, "\"\r\n"], State).

%% @doc: Executes the given command synchronously, expects Redis to
%% return "+OK\r\n", otherwise it will fail.
do_sync_command(Command, State) ->
    _ = set_socket_opts([{active, false}], State),
    TransportModule = State#state.transport_module,
    Socket = State#state.socket,
    case TransportModule:send(Socket, Command) of
        ok ->
            %% Hope there's nothing else coming down on the socket..
            case TransportModule:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, <<"+OK\r\n">>} ->
                    _ = set_socket_opts([{active, once}], State),
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

read_database(undefined) ->
    undefined;
read_database(Database) when is_integer(Database) ->
    list_to_binary(integer_to_list(Database)).

handle_socket_removal(Reason, State) ->
    reply_all({error, Reason}, State#state.queue),
    case State#state.reconnect_sleep of
        no_reconnect ->
            {stop, normal, State};
        ReconnectSleep ->
            flush_socket_messages(State),
            _ = erlang:send_after(ReconnectSleep, self(), connect),
            NewState = State#state{ socket = undefined },
            {noreply, NewState}
    end.

flush_socket_messages(State) ->
    flush_socket_messages_recur(
      State#state.socket,
      State#state.transport_data_tag,
      State#state.transport_closure_tag,
      State#state.transport_error_tag).

flush_socket_messages_recur(Socket, DataTag, ClosureTag, ErrorTag) ->
    receive
        {DataTag, Socket, _Bytes} ->
            flush_socket_messages_recur(Socket, DataTag, ClosureTag, ErrorTag);
        {ClosureTag, Socket} ->
            flush_socket_messages_recur(Socket, DataTag, ClosureTag, ErrorTag);
        {ErrorTag, Socket, _Reason} ->
            flush_socket_messages_recur(Socket, DataTag, ClosureTag, ErrorTag)
    after
        0 -> ok
    end.
