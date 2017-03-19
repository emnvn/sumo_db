%%% @hidden
%%% @doc Riak storage backend implementation.
%%%
%%% Copyright 2012 Inaka &lt;hello@inaka.net&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(sumo_backend_riak).
-author("Carlos Andres Bolanos <candres.bolanos@inakanetworks.com>").
-license("Apache License 2.0").

-behaviour(gen_server).
-behaviour(sumo_backend).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% Public API.
-export([get_connection/1,
	get_conn_info/1,
	pool_name/1,
	statistic/1,
	default_strategy/0]).

%%% Exports for sumo_backend
-export([start_link/2]).

%%% Exports for gen_server
-export([ init/1
		, handle_call/3
		, handle_cast/2
		, handle_info/2
		, terminate/2
		, code_change/3
		]).

-export([create_schema/3
		,persist/3
		,persist/4
		,delete_by/4
		,delete_all/3
		,find_all/3
		,find_all/6
		,find_by/4
		,find_by/6
		,find_by/7
		,find_by/8
		,call/5]).

%% Debug
-export([get_riak_conn/1]).

-include_lib("riakc/include/riakc.hrl").
-include("sumo.hrl").

-define(THROW_TO_ERROR(X), try X catch throw:Result -> erlang:raise(error, Result, erlang:get_stacktrace()) end).

-define(Strategy, next_worker).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Types.

-type custom_strategy() :: fun(([atom()])-> Atom::atom()).
-type strategy() :: best_worker
								| random_worker
								| next_worker
								| available_worker
								| next_available_worker
								| {hash_worker, term()}
								| custom_strategy().
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(modstate, {host :: string(),
				port :: non_neg_integer(),
				opts :: [term()],
				pool_name :: binary(),
				conn :: connection(),
				worker_handler :: pid(), 
				timeout_read :: integer(),
				timeout_write :: integer(),
				timeout_mapreduce :: integer(),
				auto_reconnect :: boolean()}).

-record(state, {conn :: connection(),
		bucket   :: bucket(),
		index    :: index(),
		get_opts :: get_options(),
		put_opts :: put_options(),
		del_opts :: delete_options()}).

-type state() :: #modstate{}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% External API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link(atom(), proplists:proplist()) -> {ok, pid()}|term().
start_link(Name, Options) ->
  gen_server:start_link({local, Name}, ?MODULE, Options, []).

-spec get_connection(atom() | pid()) -> atom().
get_connection(Name) ->
  gen_server:call(Name, get_connection).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server stuff.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec init([term()]) -> {ok, pid()}.
init([undefined, State]) ->
  
  HandlerPid = spawn_link(fun() -> worker_init(State) end),
  HandlerPid ! {init_conn, self()},
  {ok, State#modstate{worker_handler = HandlerPid}};

init(Options) ->
  %% Get connection parameters
  Host = proplists:get_value(host, Options, "127.0.0.1"),
  Port = proplists:get_value(port, Options, 8087),
  PoolSize = proplists:get_value(poolsize, Options, 100),
  WritePoolSize = proplists:get_value(write_pool_size, Options, PoolSize),
  TimeoutRead = proplists:get_value(timeout_read, Options,  ?TIMEOUT_GENERAL),
  TimeoutWrite = proplists:get_value(timeout_write, Options, ?TIMEOUT_GENERAL),
  TimeoutMapReduce = proplists:get_value(timeout_mapreduce, Options, ?TIMEOUT_GENERAL),
  AutoReconnect = proplists:get_value(auto_reconnect, Options, true),
  Opts = riak_opts(Options),
  State = #modstate{host = Host, port = Port, opts = Opts, timeout_read = TimeoutRead,
			timeout_write = TimeoutWrite, timeout_mapreduce = TimeoutMapReduce,
			auto_reconnect = AutoReconnect},
  WritePoolOptions    = [ {overrun_warning, 10000}
					, {overrun_handler, {sumo_internal, report_overrun}}
					, {workers, WritePoolSize}
					, {worker, {?MODULE, [undefined, State#modstate{pool_name = ?SUMO_POOL}]}}],
  wpool:start_pool(?SUMO_POOL, WritePoolOptions),
  {ok, #modstate{host = Host, port = Port, opts = Opts}}.

%%%
%%%

create_schema(Schema, HState, Handler) ->
	wpool:call(?SUMO_POOL, {create_schema, Schema, HState, Handler}, default_strategy(), infinity).

persist( Doc, HState, Handler) ->
	wpool:call(?SUMO_POOL, {persist, Doc, HState, Handler}, default_strategy(), infinity).


persist(OldObj, Doc, HState, Handler) ->
	wpool:call(?SUMO_POOL, {persist, OldObj, Doc, HState, Handler}, default_strategy(), infinity).


delete_by(DocName, Conditions, HState, Handler) ->
	wpool:call(?SUMO_POOL, {delete_by, DocName, Conditions, HState, Handler}, default_strategy(), infinity).

delete_all(DocName, HState, Handler) ->
	wpool:call(?SUMO_POOL, {delete_all, DocName, HState, Handler}, default_strategy(), infinity).

find_all(DocName, HState, Handler) ->
	wpool:call(?SUMO_POOL, {find_all, DocName, HState, Handler}, default_strategy(), infinity).

find_all(DocName, SortFields, Limit, Offset, HState, Handler) ->
	wpool:call(?SUMO_POOL, {find_all, DocName, SortFields, Limit, Offset, HState, Handler}, default_strategy(), infinity).

find_by(DocName, Conditions, HState, Handler) ->
	wpool:call(?SUMO_POOL, {find_by, DocName, Conditions, HState, Handler}, default_strategy(), infinity).

find_by(DocName, Conditions, Limit, Offset, HState, Handler) ->
	wpool:call(?SUMO_POOL,  {find_by, DocName, Conditions, Limit, Offset, HState, Handler}, default_strategy(), infinity).

find_by(DocName, Conditions, SortFields, Limit, Offset, HState, Handler) ->
	wpool:call(?SUMO_POOL, {find_by, DocName, Conditions, SortFields, Limit, Offset, HState, Handler}, default_strategy(), infinity).

find_by(DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler) ->
	wpool:call(?SUMO_POOL, {find_by, DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler}, default_strategy(), infinity).

call(Handler, Function, Args, DocName, HState) ->
	wpool:call(?SUMO_POOL, {call, Handler, Function, Args, DocName, HState}, default_strategy(), infinity).

%% @todo: implement connection pool.
%% In other cases is a built-in feature of the client.
-spec handle_call(term(), term(), state()) -> {reply, term(), state()}.
handle_call(get_connection, _From, State = #modstate{host = Host, port = Port, opts = Opts}) ->
	{ok, Conn} = riakc_pb_socket:start_link(Host, Port, Opts),
  	{reply, Conn, State};

handle_call(get_conn_info, From, State = #modstate{worker_handler = HandlerPid}) ->
  	HandlerPid ! {get_conn_info, From},
  	{noreply, State};


handle_call({find_key, function, Fun}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {find_key, From, {function, Fun}},
	{noreply, State};

handle_call(test_ok, _From,#modstate{worker_handler = HandlerPid} = State) ->
  {reply, HandlerPid, State};

handle_call(test_crash, _From, #modstate{conn = Conn} = State) ->
  %% do something forced process died 
  % A = 1, 
  % A = 2 ,
  {reply, Conn, State};

handle_call({create_schema, Schema, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {create_schema, From, Schema, HState, Handler},
	{noreply, State};

handle_call({persist, Doc, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {persist, From, Doc, HState, Handler},
	{noreply, State};

handle_call({persist, OldObj, Doc, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {persist, From, OldObj, Doc, HState, Handler},
	{noreply, State};

handle_call({delete_by, DocName, Conditions, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {delete_by, From, DocName, Conditions, HState, Handler},
	{noreply, State};

handle_call({delete_all, DocName, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {delete_all, From, DocName, HState, Handler},
	{noreply, State};

handle_call({find_all, DocName, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {find_all, From, DocName, HState, Handler},
	{noreply, State};

handle_call({find_all, DocName, SortFields, Limit, Offset, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {find_all, From, DocName, SortFields, Limit, Offset, HState, Handler},
	{noreply, State};

handle_call({find_by, DocName, Conditions, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {find_by, From, DocName, Conditions, HState, Handler},
	{noreply, State};

handle_call({find_by, DocName, Conditions, Limit, Offset, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {find_by, From, DocName, Conditions, Limit, Offset, HState, Handler},
	{noreply, State};

handle_call({find_by, DocName, Conditions, SortFields, Limit, Offset, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid !  {find_by, From, DocName, Conditions, SortFields, Limit, Offset, HState, Handler},
	{noreply, State};

handle_call({find_by, DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid !  {find_by, From, DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler},
	{noreply, State};

handle_call({call, Handler, Function, Args, DocName, HState}, From, #modstate{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {call, From,  Handler, Function, Args, DocName, HState},
	{noreply, State};


handle_call(_Msg, _From, State) ->
  {reply, ok, State}.


-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({connected, Conn}, State) ->
	lager:debug("sumo: connected: ~p", [Conn]),
	{noreply, State};

handle_info({fail_init_conn, _Why}, State) ->
	{stop, normal, State };

handle_info(_Msg, State) -> {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> 
	lager:error("sumo: process died",[]),
  ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server stuff.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

worker_init(State) ->
	process_flag(trap_exit, true),
	work_loop(State).


work_loop(State) ->
	Conn = State#modstate.conn,
	receive
		{init_conn, Caller} ->
			NewState = case connection(State) of 
			{ok,  ConnState} ->
				Caller ! {connected, ConnState#modstate.conn},
				ConnState;
			Error ->
				Caller ! {fail_init_conn, Error},
				State
			end,
			work_loop(NewState);
		{get_conn_info, Caller} ->
			gen_server:reply(Caller, Conn),
			work_loop(State);
		{find_key, Caller, {function, Fun}} ->
			Fun(Conn),
			gen_server:reply(Caller, ok),
			work_loop(State);
		
		{create_schema, Caller,  Schema, HState, Handler} ->
			Result = handle_create_schema(Schema, HState#state{conn =Conn} , Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{persist, Caller, Doc, HState, Handler} ->
			Result =  handle_persist(Doc, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{persist, Caller, OldObj, Doc, HState, Handler} ->
			Result = handle_persist(OldObj, Doc, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{delete_by, Caller, DocName, Conditions, HState, Handler} ->
			Result =  handle_delete_by(DocName, Conditions, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{delete_all, Caller, DocName, HState, Handler} ->
			Result = handle_delete_all(DocName, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_all, Caller, DocName, HState, Handler} ->
			Result = handle_find_all(DocName, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_all, Caller,  DocName, SortFields, Limit, Offset, HState, Handler} ->
			Result = handle_find_all(DocName, SortFields, Limit, Offset, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_by, Caller, DocName, Conditions, HState, Handler} ->
			Result = handle_find_by(DocName, Conditions, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_by, Caller, DocName, Conditions, Limit, Offset, HState, Handler} ->
			Result = handle_find_by(DocName, Conditions, Limit, Offset, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_by, Caller, DocName, Conditions, SortFields, Limit, Offset, HState, Handler} ->
			Result = handle_find_by(DocName, Conditions, SortFields, Limit, Offset, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{find_by, Caller,  DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler} ->
			Result = handle_find_by( DocName, Conditions, Filter, SortFields, Limit, Offset, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);

		{call, Caller, Handler, Function, Args, DocName, HState} ->
			Result = handle_func_call(Function, Args, DocName, HState#state{conn = Conn}, Handler),
			gen_server:reply(Caller, Result),
			work_loop(State);
		{'EXIT', _From, _Reason} ->
			ok;
		_ ->
			work_loop(State)
  end.


connection(#modstate{host = Host, port = Port, auto_reconnect = AutoReconnect} = State)  ->
  case riakc_pb_socket:start_link(Host, Port, [{auto_reconnect, AutoReconnect}]) of 
	{ok, Pid} ->
	  {ok, State#modstate{conn = Pid}};
	{error, Reason} ->
	  lager:error("Failed to connect riakc_pb_socket to ~p:~p: ~p\n",
					  [Host, Port, Reason]),
	  {error, Reason}
  end.

handle_create_schema(Schema, HState, Handler) ->
	case Handler:create_schema(Schema, HState) of
		{ok, _NewState} ->  ok;
		{error, Error, _NewState} -> {error, Error}
	end.

handle_persist(Doc, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:persist(Doc, HState),
 	{OkOrError, Reply}.

handle_persist(OldObj, Doc, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:persist(OldObj, Doc, HState),
  	{OkOrError, Reply}.

handle_delete_by(DocName, Conditions, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:delete_by(DocName, Conditions, HState),
	{OkOrError, Reply}.

handle_delete_all(DocName, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:delete_all(DocName, HState),
 	{OkOrError, Reply}.

handle_find_all(DocName, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:find_all(DocName, HState),
  	{OkOrError, Reply}.

handle_find_all(DocName, SortFields, Limit, Offset, HState, Handler) ->
  	{OkOrError, Reply, _} = Handler:find_all(DocName, SortFields, Limit, Offset, HState),
  	{OkOrError, Reply}.


handle_find_by(DocName, Conditions, HState, Handler) ->
 	{OkOrError, Reply, _} = Handler:find_by(DocName, Conditions, HState),
 	{OkOrError, Reply}.

handle_find_by(DocName, Conditions, Limit, Offset, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:find_by(DocName, Conditions, Limit, Offset, HState),
  	{OkOrError, Reply}.


handle_find_by(DocName, Conditions, SortFields, Limit, Offset, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:find_by(DocName, Conditions, SortFields, Limit, Offset, HState),
  	{OkOrError, Reply}.

handle_find_by( DocName, Conditions, Filter, SortFields, Limit, Offset, HState, Handler) ->
	{OkOrError, Reply, _} = Handler:find_by(DocName, Conditions, Filter, SortFields, Limit, Offset, HState),
  	{OkOrError, Reply}.


handle_func_call(Function, Args, DocName, HState, Handler) ->
	RealArgs = lists:append(Args, [DocName, HState]),
	{OkOrError, Reply, _} = erlang:apply(Handler, Function, RealArgs),
	{OkOrError, Reply}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server stuff.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_riak_conn(PoolName) ->
  case ets:lookup(sumo_pool, PoolName) of 
  [] ->
	wpool:call(PoolName, get_connection);
  Pids ->
	{_, Conn} = lists:nth(erlang:phash(erlang:timestamp(), length(Pids)), Pids),
	Conn
  end. 

-spec riak_opts([term()]) -> [term()].
riak_opts(Options) ->
  User = proplists:get_value(username, Options),
  Pass = proplists:get_value(password, Options),
  Opts0 = case User /= undefined andalso Pass /= undefined of
			true -> [{credentials, User, Pass}];
			_    -> []
		  end,
  Opts1 = case lists:keyfind(connect_timeout, 1, Options) of
			{_, V1} -> [{connect_timeout, V1}, {auto_reconnect, true}] ++ Opts0;
			_       -> [{auto_reconnect, true}] ++ Opts0
		  end,
  Opts1.


get_conn_info(write) ->
  wpool:call(?SUMO_POOL, get_conn_info);

get_conn_info(read) -> 
  wpool:call(?READ, get_conn_info);

get_conn_info(_) ->
  ok.

-spec default_strategy() -> strategy().
default_strategy() ->
	case application:get_env(worker_pool, default_strategy) of
		undefined -> ?Strategy;
		{ok, Strategy} -> Strategy
	end.

statistic(write) ->
  Get = fun proplists:get_value/2,
  InitStats = ?THROW_TO_ERROR(wpool:stats(?SUMO_POOL)),
  PoolPid = Get(supervisor, InitStats),
  Options = Get(options, InitStats),
  InitWorkers = Get(workers, InitStats),
  WorkerStatus = 
  [begin
	  WorkerStats = Get(I, InitWorkers),
	  MsgQueueLen = Get(message_queue_len, WorkerStats),
	  Memory = Get(memory, WorkerStats),
	  {status, WorkerStats, MsgQueueLen, Memory}
	end || I <- lists:seq(1, length(InitWorkers))],
	[PoolPid, Options, WorkerStatus];


statistic(_) ->
  ok.

pool_name(write) -> ?SUMO_POOL;
pool_name(_) -> ok.

