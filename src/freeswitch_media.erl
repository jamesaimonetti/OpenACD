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

%% @doc The gen_media callback module for voice calls through freeswitch.  
%% @see freeswitch_media_manager

-module(freeswitch_media).
-author("Micah").

-behaviour(gen_media).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("queue.hrl").
-include("call.hrl").
-include("agent.hrl").

-define(TIMEOUT, 10000).

-define(DEFAULT_PRIORITY, 10).

%% API
-export([
	start/3,
	start_link/3,
	get_call/1,
	%get_queue/1,
	%get_agent/1,
	%unqueue/1,
	%set_agent/3,
	dump_state/1
	]).

%% gen_media callbacks
-export([
	init/1,
	urlpop_getvars/1,
	handle_ring/3,
	handle_ring_stop/2,
	handle_answer/3,
	handle_voicemail/3,
	handle_spy/3,
	handle_announce/3,
	handle_agent_transfer/4,
	handle_queue_transfer/2,
	handle_wrapup/2,
	handle_call/4, 
	handle_cast/3, 
	handle_info/3,
	handle_warm_transfer_begin/3,
	handle_warm_transfer_cancel/2,
	handle_warm_transfer_complete/2,
	terminate/3,
	code_change/4]).

-record(state, {
	%callrec = undefined :: #call{} | 'undefined',
	cook :: pid() | 'undefined',
	queue :: string() | 'undefined',
	cnode :: atom(),
	dialstring :: string(),
	agent :: string() | 'undefined',
	agent_pid :: pid() | 'undefined',
	ringchannel :: pid() | 'undefined',
	manager_pid :: 'undefined' | any(),
	voicemail = false :: 'false' | string(),
	xferchannel :: pid() | 'undefined',
	xferuuid :: string() | 'undefined',
	in_control = false :: boolean(),
	queued = false :: boolean(),
	allow_voicemail = false :: boolean(),
	warm_transfer_uuid = undefined :: string() | 'undefined',
	ivroption :: string() | 'undefined',
	caseid :: string() | 'undefined',
	moh = "moh" :: string(),
	record_path :: 'undefined' | string()
	}).

-type(state() :: #state{}).
-define(GEN_MEDIA, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
%% @doc starts the freeswitch media gen_server.  `Cnode' is the C node the communicates directly with freeswitch.
-spec(start/3 :: (Cnode :: atom(), DialString :: string(), UUID :: string()) -> {'ok', pid()}).
start(Cnode, DialString, UUID) ->
	gen_media:start(?MODULE, [Cnode, DialString, UUID]).

-spec(start_link/3 :: (Cnode :: atom(), DialString :: string(), UUID :: string()) -> {'ok', pid()}).
start_link(Cnode, DialString, UUID) ->
	gen_media:start_link(?MODULE, [Cnode, DialString, UUID]).

%% @doc returns the record of the call freeswitch media `MPid' is in charge of.
-spec(get_call/1 :: (MPid :: pid()) -> #call{}).
get_call(MPid) ->
	gen_media:get_call(MPid).

-spec(dump_state/1 :: (Mpid :: pid()) -> #state{}).
dump_state(Mpid) when is_pid(Mpid) ->
	gen_media:call(Mpid, dump_state).
	
%%====================================================================
%% gen_media callbacks
%%====================================================================
%% @private
init([Cnode, DialString, UUID]) ->
	process_flag(trap_exit, true),
	Manager = whereis(freeswitch_media_manager),
	{DNIS, Client, Priority, CidName, CidNum} = get_info(Cnode, UUID),
	Call = #call{id = UUID, source = self(), client = Client, priority = Priority, callerid={CidName, CidNum}, dnis=DNIS},
	{ok, {#state{cnode=Cnode, manager_pid = Manager, dialstring = DialString}, Call, {inivr, [DNIS]}}}.

-spec(urlpop_getvars/1 :: (State :: #state{}) -> [{binary(), binary()}]).
urlpop_getvars(#state{ivroption = Ivropt} = _State) ->
	[{"itxt", Ivropt}].

-spec(handle_announce/3 :: (Announcement :: string(), Callrec :: #call{}, State :: #state{}) -> {'ok', #state{}}).
handle_announce(Announcement, Callrec, State) ->
	freeswitch:sendmsg(State#state.cnode, Callrec#call.id,
		[{"call-command", "execute"},
			{"execute-app-name", "playback"},
			{"execute-app-arg", Announcement}]),
	{ok, State}.

handle_answer(Apid, Callrec, #state{xferchannel = XferChannel, xferuuid = XferUUID} = State) when is_pid(XferChannel) ->
	link(XferChannel),
	?INFO("intercepting ~s from channel ~s", [XferUUID, Callrec#call.id]),
	freeswitch:sendmsg(State#state.cnode, XferUUID,
		[{"call-command", "execute"}, {"execute-app-name", "intercept"}, {"execute-app-arg", Callrec#call.id}]),
	case State#state.record_path of
		undefined ->
			ok;
		Path ->
			?DEBUG("resuming recording for ~p", [Callrec#call.id]),
			freeswitch:api(State#state.cnode, uuid_record, Callrec#call.id ++ " start " ++ Path)
	end,
	agent:conn_cast(Apid, {mediaload, Callrec, [{<<"height">>, <<"300px">>}, {<<"title">>, <<"Server Boosts">>}]}),
	{ok, State#state{agent_pid = Apid, ringchannel = XferChannel,
			xferchannel = undefined, xferuuid = undefined, queued = false}};
handle_answer(Apid, Callrec, State) ->
	RecPath = case cpx_supervisor:get_archive_path(Callrec) of
		none ->
			?DEBUG("archiving is not configured for ~p", [Callrec#call.id]),
			undefined;
		{error, _Reason, Path} ->
			?WARNING("Unable to create requested call archiving directory for recording ~p for ~p", [Path, Callrec#call.id]),
			undefined;
		Path ->
			%% get_archive_path ensures the directory is writeable by us and exists, so this
			%% should be safe to do (the call will be hungup if creating the recording file fails)
			?DEBUG("archiving ~p to ~s.wav", [Callrec#call.id, Path]),
			freeswitch:api(State#state.cnode, uuid_setvar, Callrec#call.id ++ " RECORD_APPEND true"),
			freeswitch:api(State#state.cnode, uuid_record, Callrec#call.id ++ " start "++Path++".wav"),
			Path++".wav"
	end,
	agent:conn_cast(Apid, {mediaload, Callrec, [{<<"height">>, <<"300px">>}, {<<"title">>, <<"Server Boosts">>}]}),
	{ok, State#state{agent_pid = Apid, record_path = RecPath, queued = false}}.

handle_ring(Apid, Callrec, State) ->
	?INFO("ring to agent ~p for call ~s", [Apid, Callrec#call.id]),
	AgentRec = agent:dump_state(Apid), % TODO - we could avoid this if we had the agent's login
	F = fun(UUID) ->
		fun(ok, _Reply) ->
			freeswitch:api(State#state.cnode, uuid_bridge, UUID ++ " " ++ Callrec#call.id);
		(error, Reply) ->
			?WARNING("originate failed: ~p; agent:  ~s, call: ~p", [Reply, AgentRec#agent.login, Callrec#call.id]),
			ok
		end
	end,
	case freeswitch_ring:start(State#state.cnode, AgentRec, Apid, Callrec, 600, F) of
		{ok, Pid} ->
			link(Pid),
			{ok, [{"itxt", State#state.ivroption}], State#state{ringchannel = Pid, agent_pid = Apid}};
		{error, Error} ->
			?ERROR("error ringing agent:  ~p; agent:  ~s call: ~p", [Error, AgentRec#agent.login, Callrec#call.id]),
			{invalid, State}
	end.

handle_ring_stop(Callrec, #state{xferchannel = RingChannel} = State) when is_pid(RingChannel) ->
	?DEBUG("hanging up transfer channel for ~p", [Callrec#call.id]),
	freeswitch_ring:hangup(RingChannel),
	{ok, State#state{xferchannel = undefined, xferuuid = undefined}};
handle_ring_stop(Callrec, State) ->
	?DEBUG("hanging up ring channel for ~p", [Callrec#call.id]),
	case State#state.ringchannel of
		undefined ->
			ok;
		RingChannel ->
			% TODO - make sure the call didn't get bridged in the interim?
			% the ring channel might have bridged and the message is sitting in our mailbox
			freeswitch_ring:hangup(RingChannel)
	end,
	{ok, State#state{ringchannel=undefined}}.

-spec(handle_voicemail/3 :: (Agent :: pid() | 'undefined', Call :: #call{}, State :: #state{}) -> {'ok', #state{}}).
handle_voicemail(Agent, Callrec, State) when is_pid(Agent) ->
	{ok, Midstate} = handle_ring_stop(Callrec, State),
	handle_voicemail(undefined, Callrec, Midstate);
handle_voicemail(undefined, Call, State) ->
	UUID = Call#call.id,
	freeswitch:bgapi(State#state.cnode, uuid_transfer, UUID ++ " 'playback:IVR/prrec.wav,gentones:%(500\\,0\\,500),sleep:600,record:/tmp/${uuid}.wav' inline"),
	{ok, State#state{voicemail = "/tmp/"++UUID++".wav"}}.

-spec(handle_spy/3 :: (Agent :: pid(), Call :: #call{}, State :: #state{}) -> {'error', 'bad_agent', #state{}} | {'ok', #state{}}).
handle_spy(Agent, Call, #state{cnode = Fnode, ringchannel = Chan} = State) when is_pid(Chan) ->
	case agent_manager:find_by_pid(Agent) of
		notfound ->
			{error, bad_agent, State};
		AgentName ->
			agent:blab(Agent, "While spying, you have the following options:\n"++
				"* To whisper to the agent; press 1\n"++
				"* To whisper to the caller; press 2\n"++
				"* To talk to both parties; press 3\n"++
				"* To resume spying; press 0"),
			freeswitch:bgapi(Fnode, originate, "user/" ++ re:replace(AgentName, "@", "_", [{return, list}]) ++ " &eavesdrop(" ++ Call#call.id ++ ")"),
			{ok, State}
	end;
handle_spy(_Agent, _Call, State) ->
	{invalid, State}.

handle_agent_transfer(AgentPid, Timeout, Call, State) ->
	AgentRec = agent:dump_state(AgentPid), % TODO - avoid this
	?INFO("transfer_agent to ~p for call ~p", [AgentRec#agent.login, Call#call.id]),
	% fun that returns another fun when passed the UUID of the new channel
	% (what fun!)
	F = fun(_UUID) ->
		fun(ok, _Reply) ->
			% agent picked up?
				?INFO("Agent transfer picked up? ~p", [Call#call.id]);
		(error, Reply) ->
			?WARNING("originate failed for ~p with  ~p", [Call#call.id, Reply])
		end
	end,
	case freeswitch_ring:start_link(State#state.cnode, AgentRec, AgentPid, Call, Timeout, F, [single_leg, no_oncall_on_bridge]) of
		{ok, Pid} ->
			{ok, [{"ivropt", State#state.ivroption}, {"caseid", State#state.caseid}], State#state{xferchannel = Pid, xferuuid = freeswitch_ring:get_uuid(Pid)}};
		{error, Error} ->
			?ERROR("error:  ~p", [Error]),
			{error, Error, State}
	end.

-spec(handle_warm_transfer_begin/3 :: (Number :: pos_integer(), Call :: #call{}, State :: #state{}) -> {'ok', string(), #state{}} | {'error', string(), #state{}}).
handle_warm_transfer_begin(Number, Call, #state{agent_pid = AgentPid, cnode = Node, ringchannel = undefined} = State) when is_pid(AgentPid) ->
	case freeswitch:api(Node, create_uuid) of
		{ok, NewUUID} ->
			?NOTICE("warmxfer UUID for ~p is ~p", [Call#call.id, NewUUID]),
			F = fun(RingUUID) ->
					fun(ok, _Reply) ->
							Client = Call#call.client,
							CalleridArgs = case proplists:get_value(<<"callerid">>, Client#client.options) of
								undefined ->
									["origination_privacy=hide_namehide_number"];
								CalleridNum ->
									["origination_caller_id_name='"++Client#client.label++"'", "origination_caller_id_number='"++binary_to_list(CalleridNum)++"'"]
							end,

							freeswitch:bgapi(Node, uuid_setvar, RingUUID ++ " ringback %(2000,4000,440.0,480.0)"),
							freeswitch:sendmsg(Node, RingUUID,
								[{"call-command", "execute"},
									{"execute-app-name", "bridge"},
									{"execute-app-arg",
										freeswitch_media_manager:do_dial_string(State#state.dialstring, Number, ["origination_uuid="++NewUUID | CalleridArgs])}]);
						(error, Reply) ->
							?WARNING("originate failed for ~p with ~p", [Call#call.id, Reply]),
							ok
					end
			end,

			Self = self(),

			F2 = fun(_RingUUID, EventName, _Event) ->
					case EventName of
						"CHANNEL_BRIDGE" ->
							case State#state.record_path of
								undefined ->
									ok;
								Path ->
									?DEBUG("switching to recording the 3rd party leg for ~p", [Call#call.id]),
									freeswitch:api(Node, uuid_record, Call#call.id ++ " stop " ++ Path),
									freeswitch:api(Node, uuid_record, NewUUID ++ " start " ++ Path)
							end,
							Self ! warm_transfer_succeeded;
						_ ->
							ok
					end,
					true
			end,

			AgentState = agent:dump_state(AgentPid), % TODO - avoid

			case freeswitch_ring:start(Node, AgentState, AgentPid, Call, 600, F, [no_oncall_on_bridge, {eventfun, F2}, {needed_events, ['CHANNEL_BRIDGE']}]) of
				{ok, Pid} ->
					link(Pid),
					{ok, NewUUID, State#state{ringchannel = Pid, warm_transfer_uuid = NewUUID}};
				{error, Error} ->
					?ERROR("error when starting ring channel for ~p :  ~p", [Call#call.id, Error]),
					{error, Error, State}
			end;
		Else ->
			{error, Else, State}
	end;
handle_warm_transfer_begin(Number, Call, #state{agent_pid = AgentPid, cnode = Node} = State) when is_pid(AgentPid) ->
	case freeswitch:api(Node, create_uuid) of
		{ok, NewUUID} ->
			?NOTICE("warmxfer UUID for ~p is ~p", [Call#call.id, NewUUID]),
			freeswitch:api(Node, uuid_setvar, Call#call.id++" park_after_bridge true"),

			case State#state.record_path of
				undefined ->
					ok;
				Path ->
					?DEBUG("switching to recording the 3rd party leg for ~p", [Call#call.id]),
					freeswitch:api(Node, uuid_record, Call#call.id ++ " stop " ++ Path),
					freeswitch:api(Node, uuid_record, NewUUID ++ " start " ++ Path)
			end,

			Client = Call#call.client,

			CalleridArgs = case proplists:get_value(<<"callerid">>, Client#client.options) of
				undefined ->
					["origination_privacy=hide_namehide_number"];
				CalleridNum ->
					["origination_caller_id_name=\\\\'"++Client#client.label++"\\\\'", "origination_caller_id_number=\\\\'"++binary_to_list(CalleridNum)++"\\\\'"]
			end,

			Dialplan = " 'm:^:bridge:"++ re:replace(freeswitch_media_manager:do_dial_string(State#state.dialstring, Number, ["origination_uuid="++NewUUID | CalleridArgs]), ",", ",", [{return, list}, global]) ++ "' inline",
			?NOTICE("~s", [Dialplan]),

			freeswitch:bgapi(Node, uuid_setvar, freeswitch_ring:get_uuid(State#state.ringchannel) ++ " ringback %(2000,4000,440.0,480.0)"),

			freeswitch:bgapi(State#state.cnode, uuid_transfer,
				freeswitch_ring:get_uuid(State#state.ringchannel) ++ Dialplan), 

			% play musique d'attente 
			freeswitch:sendmsg(Node, Call#call.id,
				[{"call-command", "execute"},
					{"execute-app-name", "playback"},
					{"execute-app-arg", "local_stream://" ++ State#state.moh}]),
			{ok, NewUUID, State#state{warm_transfer_uuid = NewUUID}};
		Else ->
			?ERROR("bgapi call failed for ~p with ~p", [Call#call.id, Else]),
			{error, "create_uuid failed", State}
	end;
handle_warm_transfer_begin(_Number, Call, #state{agent_pid = AgentPid} = State) ->
	?WARNING("wtf?! agent pid is ~p for ~p", [AgentPid, Call#call.id]),
	{error, "error: no agent bridged to this call", State}.

-spec(handle_warm_transfer_cancel/2 :: (Call :: #call{}, State :: #state{}) -> 'ok' | {'error', string(), #state{}}).
handle_warm_transfer_cancel(Call, #state{warm_transfer_uuid = WUUID, cnode = Node, ringchannel = Ring} = State) when is_list(WUUID), is_pid(Ring) ->
	RUUID = freeswitch_ring:get_uuid(Ring),
	%?INFO("intercepting ~s from channel ~s", [RUUID, Call#call.id]),
	case State#state.record_path of
		undefined ->
			ok;
		Path ->
			?DEBUG("switching back to recording the original leg for ~p", [Call#call.id]),
			freeswitch:api(Node, uuid_record, WUUID ++ " stop " ++ Path),
			freeswitch:api(Node, uuid_record, Call#call.id ++ " start " ++ Path)
	end,

	%Result = freeswitch:sendmsg(State#state.cnode, RUUID,
		%[{"call-command", "execute"}, {"execute-app-name", "intercept"}, {"execute-app-arg", Call#call.id}]),
	%?NOTICE("intercept result: ~p", [Result]),
	Result = freeswitch:api(State#state.cnode, uuid_bridge,  RUUID ++" " ++Call#call.id),
	?INFO("uuid_bridge result for ~p: ~p", [Call#call.id, Result]),
	{ok, State#state{warm_transfer_uuid = undefined}};
handle_warm_transfer_cancel(Call, #state{warm_transfer_uuid = WUUID, cnode = Node, agent_pid = AgentPid} = State) when is_list(WUUID) ->
	case freeswitch:api(Node, create_uuid) of
		{ok, NewUUID} ->
			?NOTICE("warmxfer UUID for ~p is ~p", [Call#call.id, NewUUID]),
			F = fun(RingUUID) ->
					fun(ok, _Reply) ->
							case State#state.record_path of
								undefined ->
									ok;
								Path ->
									?DEBUG("switching back to recording the original leg for ~p", [Call#call.id]),
									freeswitch:api(Node, uuid_record, WUUID ++ " stop " ++ Path),
									freeswitch:api(Node, uuid_record, Call#call.id ++ " start " ++ Path)
							end,
							freeswitch:api(Node, uuid_bridge, RingUUID++" "++Call#call.id);
						(error, Reply) ->
							?WARNING("originate failed for ~p : ~p", [Call#call.id, Reply]),
							ok
					end
			end,

			AgentState = agent:dump_state(AgentPid), % TODO - avoid

			case freeswitch_ring:start(Node, AgentState, AgentPid, Call, 600, F, []) of
				{ok, Pid} ->
					link(Pid),
					{ok, State#state{ringchannel = Pid, warm_transfer_uuid = undefined}};
				{error, Error} ->
					?ERROR("error:  ~p", [Error]),
					{error, Error, State}
			end;
		Else ->
			{error, Else, State}
	end;
handle_warm_transfer_cancel(_Call, State) ->
	{error, "Not in warm transfer", State}.

-spec(handle_warm_transfer_complete/2 :: (Call :: #call{}, State :: #state{}) -> 'ok' | {'error', string(), #state{}}).
handle_warm_transfer_complete(Call, #state{warm_transfer_uuid = WUUID, cnode = Node} = State) when is_list(WUUID) ->
	%?INFO("intercepting ~s from channel ~s", [WUUID, Call#call.id]),
	case State#state.record_path of
		undefined ->
			ok;
		Path ->
			?DEBUG("stopping recording due to warm transfer complete ~p", [Call#call.id]),
			freeswitch:api(Node, uuid_record, WUUID ++ " stop " ++ Path)
	end,

	%Result = freeswitch:sendmsg(State#state.cnode, WUUID,
		%[{"call-command", "execute"}, {"execute-app-name", "intercept"}, {"execute-app-arg", Call#call.id}]),
	%?INFO("intercept result: ~p", [Result]),
	Result = freeswitch:api(State#state.cnode, uuid_bridge,  WUUID ++" " ++Call#call.id),
	?INFO("uuid_bridge result: ~p", [Result]),
	{ok, State#state{warm_transfer_uuid = undefined}};
handle_warm_transfer_complete(_Call, State) ->
	{error, "Not in warm transfer", State}.

handle_wrapup(_Call, State) ->
	% This intentionally left blank; media is out of band, so there's
	% no direct hangup by the agent
	{ok, State}.
	
handle_queue_transfer(Call, #state{cnode = Fnode} = State) ->
	case State#state.record_path of
		undefined ->
			ok;
		Path ->
			?DEBUG("stopping recording due to queue transfer for ~p", [Call#call.id]),
			freeswitch:api(Fnode, uuid_record, Call#call.id ++ " stop " ++ Path)
	end,
	freeswitch:api(Fnode, uuid_park, Call#call.id),
	% play musique d'attente
	% TODO this can generate an annoying warning in FS, but I don't care right now
	freeswitch:sendmsg(Fnode, Call#call.id,
		[{"call-command", "execute"},
			{"execute-app-name", "playback"},
			{"execute-app-arg", "local_stream://" ++ State#state.moh}]),
	{ok, State#state{queued = true, agent_pid = undefined}}.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private
handle_call(get_call, _From, Call, State) ->
	{reply, Call, State};
handle_call(get_agent, _From, _Call, State) ->
	{reply, State#state.agent_pid, State};
handle_call({set_agent, Agent, Apid}, _From, _Call, State) ->
	{reply, ok, State#state{agent = Agent, agent_pid = Apid}};
handle_call(dump_state, _From, _Call, State) ->
	{reply, State, State};
handle_call(Msg, _From, Call, State) ->
	?INFO("unhandled mesage ~p for ~p", [Msg, Call#call.id]),
	{reply, ok, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast({"audiolevel", Arguments}, Call, State) ->
	?INFO("uuid_audio ~s", [Call#call.id++" start "++proplists:get_value("target", Arguments)++" level "++proplists:get_value("value", Arguments)]),
	freeswitch:bgapi(State#state.cnode, uuid_audio, Call#call.id++" start "++proplists:get_value("target", Arguments)++" level "++proplists:get_value("value", Arguments)),
	{noreply, State};
handle_cast({set_caseid, CaseID}, Call, State) ->
	?INFO("setting caseid for ~p to ~p", [Call#call.id, CaseID]),
	{noreply, State#state{caseid = CaseID}};
handle_cast(_Msg, _Call, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info(check_recovery, Call, State) ->
	case whereis(freeswitch_media_manager) of
		Pid when is_pid(Pid) ->
			link(Pid),
			gen_server:cast(freeswitch_media_manager, {notify, Call#call.id, self()}),
			{noreply, State#state{manager_pid = Pid}};
		_Else ->
			{ok, Tref} = timer:send_after(1000, check_recovery),
			{noreply, State#state{manager_pid = Tref}}
	end;
handle_info({'EXIT', Pid, Reason}, Call, #state{xferchannel = Pid} = State) ->
	?WARNING("Handling transfer channel ~w exit ~p for ~p", [Pid, Reason, Call#call.id]),
	{stop_ring, State#state{xferchannel = undefined}};
handle_info({'EXIT', Pid, Reason}, Call, #state{ringchannel = Pid, warm_transfer_uuid = W} = State) when is_list(W) ->
	?WARNING("Handling ring channel ~w exit ~p while in warm transfer for ~p", [Pid, Reason, Call#call.id]),
	agent:media_push(State#state.agent_pid, warm_transfer_failed),
	cdr:warmxfer_fail(Call, State#state.agent_pid),
	{noreply, State#state{ringchannel = undefined}};
handle_info(warm_transfer_succeeded, Call, #state{warm_transfer_uuid = W} = State) when is_list(W) ->
	?DEBUG("Got warm transfer success notification from ring channel for ~p", [Call#call.id]),
	agent:media_push(State#state.agent_pid, warm_transfer_succeeded),
	{noreply, State};
handle_info({'EXIT', Pid, Reason}, Call, #state{ringchannel = Pid} = State) ->
	?WARNING("Handling ring channel ~w exit ~p for ~p", [Pid, Reason, Call#call.id]),
	{stop_ring, State#state{ringchannel = undefined}};
handle_info({'EXIT', Pid, Reason}, Call, #state{manager_pid = Pid} = State) ->
	?WARNING("Handling manager exit from ~w due to ~p for ~p", [Pid, Reason, Call#call.id]),
	{ok, Tref} = timer:send_after(1000, check_recovery),
	{noreply, State#state{manager_pid = Tref}};
handle_info({call, {event, [UUID | Rest]}}, Call, State) when is_list(UUID) ->
	?DEBUG("reporting new call ~p.", [UUID]),
	freeswitch:session_nixevent(State#state.cnode, 'ALL'),
	freeswitch:session_event(State#state.cnode, ['CHANNEL_PARK', 'CHANNEL_HANGUP', 'CHANNEL_HANGUP_COMPLETE', 'CHANNEL_DESTROY', 'DTMF']),
	freeswitch_media_manager:notify(UUID, self()),
	case_event_name([UUID | Rest], Call, State#state{in_control = true});
handle_info({call_event, {event, [UUID | Rest]}}, Call, State) when is_list(UUID) ->
	%?DEBUG("reporting existing call progess ~p.", [UUID]),
	case_event_name([ UUID | Rest], Call, State);
handle_info({set_agent, Login, Apid}, _Call, State) ->
	{noreply, State#state{agent = Login, agent_pid = Apid}};
handle_info({bgok, Reply}, Call, State) ->
	?DEBUG("bgok:  ~p for ~p", [Reply, Call#call.id]),
	{noreply, State};
handle_info({bgerror, "-ERR NO_ANSWER\n"}, Call, State) ->
	?INFO("Potential ringout.  Statecook:  ~p for ~p", [State#state.cook, Call#call.id]),
	%% the apid is known by gen_media, let it handle if it is not not.
	{stop_ring, State};
handle_info({bgerror, "-ERR USER_BUSY\n"}, Call, State) ->
	?NOTICE("Agent rejected the call ~p", [Call#call.id]),
	{stop_ring, State};
handle_info({bgerror, Reply}, Call, State) ->
	?WARNING("unhandled bgerror: ~p for ~p", [Reply, Call#call.id]),
	{noreply, State};
handle_info(channel_destroy, Call, #state{in_control = InControl} = State) when not InControl ->
	?NOTICE("Hangup in IVR for ~p", [Call#call.id]),
	{stop, hangup, State};
handle_info(call_hangup, Call, State) ->
	?NOTICE("Call hangup info, terminating ~p", [Call#call.id]),
	catch freeswitch_ring:hangup(State#state.ringchannel),
	{stop, normal, State};
handle_info(Info, Call, State) ->
	?INFO("unhandled info ~p for ~p", [Info, Call#call.id]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, Call, _State) ->
	?NOTICE("terminating: ~p ~p", [Reason, Call#call.id]),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, _Call, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @private
case_event_name([UUID | Rawcall], Callrec, State) ->
	Ename = proplists:get_value("Event-Name", Rawcall),
	%?DEBUG("Event:  ~p;  UUID:  ~p", [Ename, UUID]),
	case Ename of
		"CHANNEL_PARK" ->
			case State#state.queued of
				false when State#state.warm_transfer_uuid == undefined ->
					Queue = proplists:get_value("variable_queue", Rawcall, "default_queue"),
					Client = proplists:get_value("variable_brand", Rawcall),
					AllowVM = proplists:get_value("variable_allow_voicemail", Rawcall, false),
					Moh = proplists:get_value("variable_queue_moh", Rawcall, "moh"),
					P = proplists:get_value("variable_queue_priority", Rawcall, integer_to_list(?DEFAULT_PRIORITY)),
					Ivropt = proplists:get_value("variable_ivropt", Rawcall),
					Priority = try list_to_integer(P) of
						Pri -> Pri
					catch
						error:badarg -> ?DEFAULT_PRIORITY
					end,
					Calleridname = proplists:get_value("Caller-Caller-ID-Name", Rawcall, "Unknown"),
					Calleridnum = proplists:get_value("Caller-Caller-ID-Number", Rawcall, "Unknown"),
					Doanswer = proplists:get_value("variable_erlang_answer", Rawcall, true),
					NewCall = Callrec#call{client=Client, callerid={Calleridname, Calleridnum}, priority = Priority},
					case Doanswer of
						"false" ->
							ok;
						_ ->
							freeswitch:sendmsg(State#state.cnode, UUID,
								[{"call-command", "execute"},
									{"execute-app-name", "answer"}])
					end,
					freeswitch:bgapi(State#state.cnode, uuid_setvar, UUID ++ " hangup_after_bridge true"),
					% play musique d'attente
					freeswitch:sendmsg(State#state.cnode, UUID,
						[{"call-command", "execute"},
							{"execute-app-name", "playback"},
							{"execute-app-arg", "local_stream://"++Moh}]),
						%% tell gen_media to (finally) queue the media
					{queue, Queue, NewCall, State#state{queue = Queue, queued=true, allow_voicemail=AllowVM, moh=Moh, ivroption = Ivropt}};
				_Otherwise ->
					{noreply, State}
			end;
		"CHANNEL_HANGUP" when is_list(State#state.warm_transfer_uuid) and is_pid(State#state.ringchannel) ->
			?NOTICE("caller hung up while agent was talking to third party ~p", [Callrec#call.id]),
			RUUID = freeswitch_ring:get_uuid(State#state.ringchannel),
			% notify the agent that the caller hung up via some beeping
			freeswitch:bgapi(State#state.cnode, uuid_displace,
				RUUID ++ " start tone_stream://v=-7;%(100,0,941.0,1477.0);v=-7;>=2;+=.1;%(1400,0,350,440) mux"),
			agent:blab(State#state.agent_pid, "Caller hung up, sorry."),
			cdr:warmxfer_fail(Callrec, State#state.agent_pid),
			{{hangup, "caller"}, State};
		"CHANNEL_HANGUP_COMPLETE" ->
			?DEBUG("Channel hangup ~p", [Callrec#call.id]),
			Apid = State#state.agent_pid,
			case Apid of
				undefined ->
					?WARNING("Agent undefined ~p", [Callrec#call.id]),
					State2 = State#state{agent = undefined, agent_pid = undefined};
				_Other ->
					try agent:query_state(Apid) of
						{ok, ringing} ->
							?NOTICE("caller hung up while we were ringing an agent ~p", [Callrec#call.id]),
							case State#state.ringchannel of
								undefined ->
									ok;
								RingChannel ->
									freeswitch_ring:hangup(RingChannel)
							end;
						_Whatever ->
							ok
					catch
						exit:{noproc, _} ->
							?WARNING("agent ~p is a dead pid ~p", [Apid, Callrec#call.id])
					end,
					State2 = State#state{agent = undefined, agent_pid = undefined, ringchannel = undefined}
			end,
			case State#state.voicemail of
				false -> % no voicemail
					ok;
				FileName ->
					case filelib:is_regular(FileName) of
						true ->
							?NOTICE("~s left a voicemail", [UUID]),
							Client = Callrec#call.client,
							freeswitch_media_manager:new_voicemail(UUID, FileName, State#state.queue, Callrec#call.priority + 10, Client#client.id);
						false ->
							?NOTICE("~s hungup without leaving a voicemail", [UUID])
					end
			end,
		%	{hangup, State2};
		%"CHANNEL_HANGUP_COMPLETE" ->
			% TODO - this is protocol specific and we only handle SIP right now
			% TODO - this should go in the CDR
			Cause = proplists:get_value("variable_hangup_cause", Rawcall),
			Who = case proplists:get_value("variable_sip_hangup_disposition", Rawcall) of
				"recv_bye" ->
					?DEBUG("Caller hungup ~p, cause ~p", [UUID, Cause]),
					"caller";
				"send_bye" ->
					?DEBUG("Agent hungup ~p, cause ~p", [UUID, Cause]),
					"agent";
				_ ->
					?DEBUG("I don't know who hung up ~p, cause ~p", [UUID, Cause]),
					undefined
				end,
			%{noreply, State};
			{{hangup, Who}, State2};
		"CHANNEL_DESTROY" ->
			?DEBUG("Last message this will recieve, channel destroy ~p", [Callrec#call.id]),
			{stop, normal, State};
		"DTMF" ->
			case proplists:get_value("DTMF-Digit", Rawcall) of
				"*" when State#state.allow_voicemail =/= false, State#state.queued == true ->
					% allow the media to go to voicemail
					?NOTICE("caller requested to go to voicemail ~p", [Callrec#call.id]),
					freeswitch:bgapi(State#state.cnode, uuid_transfer, UUID ++ " 'playback:IVR/prrec.wav,gentones:%(500\\,0\\,500),sleep:600,record:/tmp/${uuid}.wav' inline"),
					case State#state.ringchannel of
						undefined ->
							ok;
						RingChannel ->
							freeswitch_ring:hangup(RingChannel)
					end,
					{voicemail, State#state{voicemail = "/tmp/"++UUID++".wav"}};
				"*" ->
					?NOTICE("caller attempted to go to voicemail but is not allowed to do so ~p", [Callrec#call.id]),
					{noreply, State};
				_ ->
					{noreply, State}
			end;
		{error, notfound} ->
			?WARNING("event name not found: ~p for ~p", [proplists:get_value("Content-Type", Rawcall), Callrec#call.id]),
			{noreply, State};
		_Else ->
			%?DEBUG("Event unhandled ~p", [_Else]),
			{noreply, State}
	end.

get_info(Cnode, UUID) ->
	get_info(Cnode, UUID, 0).

get_info(Cnode, UUID, Retries) when Retries < 2 ->
	case freeswitch:api(Cnode, uuid_dump, UUID) of
		{ok, Result} ->
			Proplist = lists:foldl(
				fun([], Acc) ->
						Acc;
					(String, Acc) ->
						[Key, Value] = util:string_split(String, ": ", 2),
						[{Key, Value} | Acc]
				end, [], util:string_split(Result, "\n")),

			Priority = try list_to_integer(proplists:get_value("variable_queue_priority", Proplist, "")) of
				Pri -> Pri
			catch
				error:badarg ->
					?DEFAULT_PRIORITY
			end,

			{proplists:get_value("Caller-Destination-Number", Proplist, ""),
				proplists:get_value("variable_brand", Proplist, ""), Priority,
				proplists:get_value("Caller-Caller-ID-Name", Proplist, "Unknown"),
				proplists:get_value("Caller-Caller-ID-Number", Proplist, "Unknown")
			};
		timeout ->
			?WARNING("uuid_dump for ~s timed out. Retrying", [UUID]),
			%{"", "", 10, "Unknown", "Unknown"};
			get_info(Cnode, UUID, Retries + 1);
		{error, Error} ->
			?WARNING("uuid_dump for ~s errored:  ~p. Retrying", [UUID, Error]),
			%{"", "", 10, "Unknown", "Unknown"}
			get_info(Cnode, UUID, Retries + 1)
	end;
get_info(_, UUID, _) ->
	?WARNING("Too many failures doing uuid_dump for ~p", [UUID]),
	{"", "", ?DEFAULT_PRIORITY, "Unknown", "Unknown"}.

