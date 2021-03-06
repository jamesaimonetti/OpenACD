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

%% @doc The media manager for handling email.  This starts the email server
%% listener.  The listener passes off to the email_media_session callback.
%% When the email_media_session callback is ready for an email to enter queue, 
%% it sends a message back here for an email_media to be created and queued.
-module(email_media_manager).
-author(openacd).

-behaviour(gen_server).

%% API
-export([
	start_link/1,
	start/1,
	stop/0,
	get_mappings/0,
	set_mapping/2,
	new_mapping/1,
	destroy_mapping/1,
	requeue/1,
	batch_requeue/1,
	get_send_opts/0,
	get_media/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("smtp.hrl").
-include("call.hrl").
-include_lib("stdlib/include/qlc.hrl").

-record(state, {
	mails = [] :: [pid()],
	relays = [] :: [string()],
	server :: pid(),
	conf = [] :: [{atom(), any()}],
	send_conf = [] :: [{atom(), any()}]
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
-spec(start_link/1 :: (Options :: [any()]) -> {'ok', pid()}).
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

-spec(start/1 :: (Options :: [any()]) -> {'ok', pid()}).
start(Options) ->
	gen_server:start({local, ?MODULE}, ?MODULE, [Options], []).

-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:call(?MODULE, stop).

-spec(get_mappings/0 :: () -> {'atomic', [#mail_map{}]} | {'aborted', any()}).
get_mappings() ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(mail_map)]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).

-spec(set_mapping/2 :: (Address :: string(), Options :: #mail_map{} | [any()]) -> {'atomic', 'ok'} | {'aborted', any()}).
set_mapping(Address, Options) when is_list(Options) ->
	Rec = #mail_map{
		address = proplists:get_value(address, Options),
		queue = proplists:get_value(queue, Options, "default_queue"),
		skills = proplists:get_value(skills, Options, []),
		client = proplists:get_value(client, Options)
	},
	set_mapping(Address, Rec);		
set_mapping(Address, Rec) when is_record(Rec, mail_map) ->
	F = fun() ->
		mnesia:delete({mail_map, Address}),
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

-spec(new_mapping/1 :: (Options :: #mail_map{} | [any()]) -> {'atomic', 'ok'} | {'aborted', any()}).
new_mapping(Options) when is_list(Options) ->
	Rec = #mail_map{
		address = proplists:get_value(address, Options),
		queue = proplists:get_value(queue, Options, "default_queue"),
		skills = proplists:get_value(skills, Options, []),
		client = proplists:get_value(client, Options)
	},
	new_mapping(Rec);
new_mapping(Rec) when is_record(Rec, mail_map) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

-spec(destroy_mapping/1 :: (Address :: string()) -> {'atomic', 'ok'} | {'aborted', any()}).
destroy_mapping(Address) ->
	F = fun() ->
		mnesia:delete({mail_map, Address})
	end,
	mnesia:transaction(F).

-spec(requeue/1 :: (Filename :: string()) -> 'ok').
requeue(Filename) ->
	gen_server:cast(email_media_manager, {queue, Filename}).

-spec(batch_requeue/1 :: (Dir :: string()) -> 'ok').
batch_requeue(Dir) ->
	gen_server:cast(email_media_manager, {batch_queue, Dir}).

-spec(get_send_opts/0 :: () -> {ok, [{atom(), any()}]}).
get_send_opts() ->
	gen_server:call(?MODULE, get_send_opts).

-spec(get_media/1 :: (MediaKey :: pid() | string()) -> {string(), pid()} | 'none').
get_media(MediaKey) ->
	gen_server:call(?MODULE, {get_media, MediaKey}).
	
%-ifndef(NOWEB).
%web_api(_Message, _Post) ->
%	{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"nyi">>}]})}.
%-endif.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%--------------------------------------------------------------------
init([Options]) ->
	process_flag(trap_exit, true),
	build_table(),
	%% the smtp server doesn't die along w/ this (it's trapping exits and
	%% throwing away anything not from a session).  So, when this starts, if
	%% something's not already registered, it will attempt to start the server
	%% and register.  If the server fails to start for any reason, this will
	%% die a horrible death (which is good!).

	% TODO - I think there's a race condition here, why can't the smtp server die
	% along with this process and make things simpler?
	Pid = case whereis(cpx_smtp_server) of
		undefined ->
			{ok, Server} = gen_smtp_server:start(email_media_session, [Options]),
			register(cpx_smtp_server, Server),
			link(Server),
			Server;
		Reg when is_pid(Reg) ->
			link(Reg),
			Reg
	end,
	{ProtoSendOpts, _} = proplists:split(Options, [tls, ssl, password, username, auth, outport, outbound]),
	Fixopts = fun
		([{outbound, Val}], Acc) ->
			[{relay, Val} | Acc];
		([{outport, Val}], Acc) ->
			[{port, Val} | Acc];
		([{Key, Val}], Acc) ->
			[{Key, Val} | Acc];
		([], Acc) ->
			Acc
	end,
	FixedSend = lists:foldl(Fixopts, [], ProtoSendOpts),
	State = #state{
		server = Pid,
		conf = Options,
		relays = proplists:get_value(relays, Options, []),
		send_conf = FixedSend
	},
	{ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(stop, From, State) ->
	?INFO("Received request to stop from ~p", [From]),
	{stop, normal, ok, State};
handle_call(get_send_opts, _From, #state{send_conf = Sendconfs} = State) ->
	{reply, {ok, Sendconfs}, State};
handle_call({queue, Mailmap, Id, Data}, _From, #state{mails = Mails} = State) ->
	case right_time(Mailmap#mail_map.client) of
		true ->
			case email_media:start([{mail_map, Mailmap}, {raw, Data}, {id, Id}]) of
				{ok, Mpid} ->
					link(Mpid),
					{reply, ok, State#state{mails = [{Id, Mpid} | Mails]}};
				Else ->
					?WARNING("couldn't queue message due to ~p", [Else]),
					{reply, {error, Else}, State}
			end;
		false ->
			{reply, {error, not_right_time}, State}
	end;
handle_call({queue, Id, Pid}, _From, #state{mails = Mails} = State) ->
	{Newmails, Reply} = case proplists:get_value(Id, Mails) of
		undefined ->
			link(Pid),
			{[{Id, Pid} | Mails], ok};
		Pid ->
			link(Pid),
			{Mails, ok};
		Err ->
			?ERROR("informed that ~p was queued, but existing pid (~p) doesn't match stashed pid(~p)", [Id, Err, Pid]),
			{Mails, {error, duplicate}}
	end,
	{reply, Reply, State#state{mails = Newmails}};
handle_call({right_time, Mailmap}, _From, State) ->
	Res = right_time(Mailmap#mail_map.client),
	{reply, Res, State};
handle_call({get_media, MediaPid}, _From, #state{mails = Mails} = State) when is_pid(MediaPid) ->
	case lists:keyfind(MediaPid, 2, Mails) of
		false ->
			{reply, none, State};
		{Id, MediaPid} ->
			{reply, {Id, MediaPid}, State}
	end;
handle_call({get_media, MediaKey}, _From, #state{mails = Mails} = State) ->
	case proplists:get_value(MediaKey, Mails) of
		undefined ->
			{reply, none, State};
		Pid ->
			{reply, {MediaKey, Pid}, State}
	end;
handle_call(list, _From, #state{mails = Mails} = State) ->
	{reply, Mails, State};
handle_call(Request, _From, State) ->
    {reply, {invalid, Request}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast({queue, Filename}, #state{mails = Mails} = State) ->
	case file:read_file(Filename) of
		{error, Error} ->
			?INFO("Error reading file ~p:  ~p", [Filename, Error]),
			{noreply, State};
		{ok, Email} ->
			case email_media:start([{raw, Email}]) of
				{ok, Mpid} ->
					link(Mpid),
					#call{id = Id} = gen_media:get_call(Mpid),
					{noreply, State#state{mails = [{Id, Mpid} | Mails]}};
				Else ->
					?WARNING("Couldn't start new mail media due to ~p", [Else]),
					{noreply, State}
			end
	end;
handle_cast({batch_queue, Dir}, State) ->
	case file:list_dir(Dir) of
		{ok, Files} ->
			Fun = fun() ->
				lists:foreach(
					fun(Elem) -> 
						email_media_manager:requeue(lists:append([Dir, "/", Elem]))
					end, Files)
			end,
			spawn(Fun);
		{error, Reason} ->
			?INFO("batch requeue failed due to ~p", [Reason])
	end,
	{noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, #state{server = Pid} = State) ->
	?WARNING("The server at ~w exited due to ~p", [Pid, Reason]),
	{stop, {server_exit, Reason}, State#state{server = undefined}};
handle_info({'EXIT', From, Reason}, #state{mails = Mails} = State) ->
	?DEBUG("Handling exit from ~w due to ~p", [From, Reason]),
	Newmail = case Reason of
		normal ->
			lists:keydelete(From, 2, Mails);
		_ ->
			case lists:keyfind(From, 2, Mails) of
				{Id, From} ->
					% TODO we might be able to do more than a truncate.
					cdr:truncate(Id),
					lists:keydelete(From, 2, Mails);
				_ ->
					?INFO("~p not in the mails list, ignoring exit", [From]),
					Mails
			end
	end,
	Newmail = lists:keydelete(From, 2, Mails),
	{noreply, State#state{mails = Newmail}};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, #state{server = undefined}) ->
	?INFO("Terminating due to ~p; no known server to drag down", [Reason]),
	ok;
terminate(Reason, State) ->
	?INFO("terminating due to ~p, taking server w/ us.", [Reason]),
	gen_smtp_server:stop(State#state.server),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

build_table() ->
	?DEBUG("Buidling table...", []),
	A = util:build_table(mail_map, [
		{attributes, record_info(fields, mail_map)},
		{disc_copies, [node()]}
	]),
	case A of
		{atomic, ok} ->
			?INFO("Writing default data...", []),
			F = fun() ->
				mnesia:write(#mail_map{address = "support@example.com"})
			end,
			mnesia:transaction(F);
		_Else when A =:= copied; A =:= exists ->
			?DEBUG("Copied the table from elsewhere.", []),
			ok;
		_Else ->
			A
	end.

right_time(undefined) ->
	true;
right_time(Client) when is_record(Client, client) ->
	EmailOverride = proplists:get_value(<<"emailoverride">>, Client#client.options, false),
	EmailStart = proplists:get_value(<<"emailstart">>, Client#client.options),
	EmailEnd = proplists:get_value(<<"emailend">>, Client#client.options),
	case {EmailOverride, EmailStart, EmailEnd} of
		{false, X, Y} when is_binary(X), is_binary(Y), X =/= Y ->
			IntStart = try_binary_to_integer(EmailStart),
			IntEnd = try_binary_to_integer(EmailEnd),
			{_, {Hour, Minute, _}} = calendar:local_time(),
			Current = Hour*100 + Minute,
			case {IntStart, IntEnd} of
				{A, B} when is_integer(A), is_integer(B) ->
					if (Current > IntStart andalso ((IntStart < IntEnd andalso Current < IntEnd) orelse (IntEnd < IntStart)));
						(IntStart > IntEnd andalso Current < IntEnd andalso Current < IntStart) ->
							true;
						true ->
							false
					end;
				_ ->
					true
			end;
		_ ->
			true
	end;
right_time(Client) when is_list(Client) ->
	case call_queue_config:get_client(id, Client) of
		none ->
			right_time(undefined);
		Else ->
			right_time(Else)
	end.

try_binary_to_integer(Bin) when is_binary(Bin) ->
	List = binary_to_list(Bin),
	try list_to_integer(List) of
		X ->
			X
	catch
		error:badarg ->
			badarg
	end.
