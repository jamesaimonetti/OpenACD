%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at fusedsolutions dot com>
%%

%% @doc Handles the creation and desctruction of dispatchers.
%% Locally registered on each node.
%% There is to be 1 dipatcher for every avaiable agent on a node.
%% @see dispatcher
-module(dispatch_manager).
-author("Micah").

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

%% API
-export([
	start_link/0,
	start/0, 
	stop/0, 
	count_dispatchers/0,
	deep_inspect/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	dispatchers = [] :: [pid()],
	agents = [] :: [pid()]
	}).
	
-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================

%% @doc start a dispatch manager linked to the calling process.
-spec(start_link/0 :: () -> {'ok', pid()}).
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc start a dispatch manager linked to no process.
-spec(start/0 :: () -> {'ok', pid()}).
start() ->
	gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @doc Stop the dispatch manager with reason `normal'.
-spec(stop/0 :: () -> any()).
stop() -> 
	gen_server:call(?MODULE, stop).

-spec(count_dispatchers/0 :: () -> non_neg_integer()).
count_dispatchers() ->
	gen_server:call(?MODULE, count_dispatchers).

-spec(deep_inspect/0 :: () -> 'ok').
deep_inspect() ->
	gen_server:cast(?MODULE, deep_inspect).
	
%%====================================================================
%% gen_server callbacks
%%====================================================================
%% @private
init([]) ->
	?DEBUG("~p starting at ~p", [?MODULE, node()]),
	process_flag(trap_exit, true),
	case whereis(agent_manager) of
		undefined ->
			{ok, #state{}};
		_Else ->
			Agents = agent_manager:list(),
			F = fun({Login, {Pid, _, Time, _}}) ->
				?DEBUG("Checking status of ~s (~p)", [Login, Pid]),
				case Time of
					0 ->
						gen_server:cast(dispatch_manager, {end_avail, Pid});
					_ ->
						gen_server:cast(dispatch_manager, {now_avail, Pid})
				end
			end,
			spawn(fun() -> 
				timer:sleep(10),
				?DEBUG("Spawn waking up with agents ~p", [Agents]),
				lists:foreach(F, Agents),
				?DEBUG("Spawn done.", [])
			end),
			{ok, #state{}}
	end.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private
handle_call(count_dispatchers, _From, State) ->
	{reply, length(State#state.dispatchers), State};
handle_call(stop, _From, State) -> 
	{stop, normal, ok, State};
handle_call(dump, _From, State) ->
	{reply, State, State};
handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast({now_avail, AgentPid}, State) -> 
	?DEBUG("Someone's available now.", []),
	case lists:member(AgentPid, State#state.agents) of
		true -> 
			{noreply, balance(State)};
		false -> 
			erlang:monitor(process, AgentPid),
			State2 = State#state{agents = [AgentPid | State#state.agents]},
			{noreply, balance(State2)}
	end;
handle_cast({end_avail, AgentPid}, State) -> 
	?DEBUG("An agent is no longer available.", []),
	State2 = State#state{agents = lists:delete(AgentPid, State#state.agents)},
	{noreply, balance(State2)};
handle_cast(deep_inspect, #state{dispatchers = Disps} = State) ->
	Fun = fun(Pid) ->
		{ok, Dispstate} = gen_server:call(Pid, dump_state),
		Queued = element(2, Dispstate),
		QueueRef = element(4, Dispstate),
		[Pid, Queued, QueueRef]
	end,
	Mapped = lists:map(Fun, Disps),
	io:format("Pid\tQueuedCall\tQueuepid~n"),
	lists:foreach(fun(L) -> io:format("~p\t~p\t~p~n", L) end, Mapped),
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info({'DOWN', _MonitorRef, process, Object, _Info}, State) -> 
	?DEBUG("Announcement that an agent is down, balancing in response.", []),
	State2 = State#state{agents = lists:delete(Object, State#state.agents)},
	{noreply, balance(State2)};
handle_info({'EXIT', Pid, Reason}, #state{dispatchers = Dispatchers} = State) ->
	case (Reason =:= normal orelse Reason =:= shutdown) of
		true ->
			%?DEBUG("Dispatcher exited normally ~p", [Pid]),
			ok;
		false ->
			?NOTICE("Dispatcher unexpected exit:  ~p ~p", [Pid, Reason])
	end,
	CleanD = lists:delete(Pid, Dispatchers),
	State2 = State#state{dispatchers = CleanD},
	{noreply, balance(State2)};
handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, State) ->
	?NOTICE("Termination cause:  ~p.  State:  ~p", [Reason, State]),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
	
%% @private
-spec(balance/1 :: (State :: #state{}) -> #state{}).
balance(#state{dispatchers = Dispatchers} = State) when length(State#state.agents) > length(Dispatchers) -> 
	?DEBUG("Starting new dispatcher",[]),
	case dispatcher:start_link() of
		{ok, Pid} ->
			balance(State#state{dispatchers = [ Pid | Dispatchers]});
		_ ->
			balance(State)
	end;
balance(State) when length(State#state.agents) < length(State#state.dispatchers) -> 
	%?DEBUG("Killing a dispatcher",[]),
	%[Pid | Dispatchers] = State#state.dispatchers,
	%?DEBUG("Pid I'm about to kill: ~p.", [Pid]),
	%try dispatcher:stop(Pid) of
		%ok ->
			% if it dies, we'll get the exit message.
			%balance(State#state{dispatchers=Dispatchers});
		%_ ->
			%balance(State#state{dispatchers=[Pid | Dispatchers]})
	%catch
		%_:_ ->
			%balance(State#state{dispatchers=Dispatchers})
	%end;
	Diff = length(State#state.dispatchers) - length(State#state.agents),
	case Diff of
		_ when Diff > 10 ->
			Dispatchers = balance_down([], lists:reverse(State#state.dispatchers), Diff, false),
			State#state{dispatchers = Dispatchers};
		_ ->
			State
	end;
balance(State) -> 
	?DEBUG("It is fully balanced!",[]),
	State.

balance_down(Out, _In, 0, _Force) ->
	lists:reverse(Out);
balance_down(Out, [], _Count, true) ->
	lists:reverse(Out);
balance_down(Out, [], Count, false) ->
	?DEBUG("switching to hard kill mode; ~p holdouts", [Count]),
	balance_down([], lists:reverse(Out), Count, true);
balance_down(Out, [D | In], Count, Force) ->
	try dispatcher:stop(D, Force) of
		ok ->
			balance_down(Out, In, Count - 1, Force);
		_ ->
			?DEBUG("dispatcher declined to die", []),
			balance_down([D | Out], In, Count, Force)
	catch
		_:_ ->
			balance_down(Out, In, Count - 1, Force)
	end.

-ifdef(TEST).

dump() ->
	gen_server:call(?MODULE, dump).

test_primer() ->
	["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
	mnesia:stop(),
	mnesia:delete_schema([node()]),
	mnesia:create_schema([node()]),
	mnesia:start().

balance_test_() ->
	{
		foreach,
		fun() ->
			test_primer(),
			agent_manager:start([node()]),
			queue_manager:start([node()]),
			start(),
			ok
		end,
		fun(ok) ->
			agent_manager:stop(),
			queue_manager:stop(),
			stop()
		end,
		[
			{
				"Agent started, but is still released",
				fun() ->
					{ok, _Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(State1#state.agents, []),
					?assertEqual(State1#state.dispatchers, [])
				end
			},
			{
				"Agent started then set available, so a dispatcher starts",
				fun() ->
					State1 = dump(),
					?assertEqual(State1#state.agents, []),
					?assertEqual(State1#state.dispatchers, []),
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([Apid], State2#state.agents),
					?assertEqual(1, length(State2#state.dispatchers))
				end
			},
			{
				"Agent died, so a dipatcher ends",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(State1#state.agents, [Apid]),
					?assertEqual(1, length(State1#state.dispatchers)),
					exit(Apid, kill),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([], State2#state.agents),
					?assertEqual([], State2#state.dispatchers)
				end
			},
			{
				"Unexpected dispatcher death",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					#state{dispatchers = [PidToKill]} = dump(),
					exit(PidToKill, test_kill),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual(1, length(State1#state.dispatchers)),
					?assertNot([PidToKill] =:= State1#state.dispatchers)
				end
			},
			{
				"Agent unavailable, do a dispatcher ends",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual([Apid], State1#state.agents),
					?assertEqual(1, length(State1#state.dispatchers)),
					agent:set_state(Apid, released, default),
					receive
					after 100 ->
						ok
					end,
					State2 = dump(),
					?assertEqual([], State2#state.agents),
					?assertEqual([], State2#state.agents)
				end
			},
			{
				"Agent avail and already tracked",
				fun() ->
					{ok, Apid} = agent_manager:start_agent(#agent{login = "testagent"}),
					agent:set_state(Apid, idle),
					receive
					after 100 ->
						ok
					end,
					State1 = dump(),
					?assertEqual([Apid], State1#state.agents),
					?assertEqual(1, length(State1#state.dispatchers)),
					gen_server:cast(?MODULE, {now_avail, Apid}),
					State2 = dump(),
					?assertEqual([Apid], State2#state.agents),
					?assertEqual(1, length(State1#state.dispatchers))
				end
			},
			{
				"Dispatcher unfortunately dies, but notices agents on it's return.",
				fun() ->
					agent_dummy_connection:start_x(10),
					Agents = agent_manager:list(),
					Setrel = fun(I) ->
						{_Login, {Pid, _, _, _}} = lists:nth(I, Agents),
						agent:set_state(Pid, released, default)
					end,
					lists:foreach(Setrel, lists:seq(1, 5)),
					#state{agents = Expectedagents, dispatchers = Unexpecteddispatchers} = gen_server:call(dispatch_manager, dump),
					exit(whereis(dispatch_manager), kill),
					timer:sleep(5),
					{ok, _Pid} = start(),
					timer:sleep(30),
					#state{agents = Newagents, dispatchers = Newdispathers} = Dump = gen_server:call(dispatch_manager, dump),
					?DEBUG("Expected:  ~p", [Expectedagents]),
					?DEBUG("New agents:  ~p", [Newagents]),
					?assertEqual(length(Expectedagents), length(Newagents)),
					?assertEqual(length(Unexpecteddispatchers), length(Newdispathers)),
					lists:foreach(fun(I) ->
						?assertNot(lists:member(I, Unexpecteddispatchers))
					end, Newdispathers),
					lists:foreach(fun(I) ->
						?assert(lists:member(I, Expectedagents))
					end, Newagents)
				end
			}
		]
	}.

-define(MYSERVERFUNC, fun() -> {ok, _Pid} = start_link(), {?MODULE, fun() -> stop() end} end).

-include("gen_server_test.hrl").

-endif.
