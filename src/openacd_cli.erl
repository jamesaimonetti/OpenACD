%% "The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 Andrew Thompson.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>

%% @doc Module for controling the OpenACD servica via erlctl

-module(openacd_cli).
-include_lib("erlctl/include/erlctl.hrl").

-compile([export_all]).

help(always, []) ->
	erlctl:format("There's no help for you here ~p~n", [node()]),
	ok.

start(running, _) ->
	erlctl:format("node: ~p~n", [node()]),
	{error, 1, "OpenACD is already running."};
start(not_running, []) ->
	{start, [], "Starting OpenACD..."};
start(started, []) ->
	ok= application:start(crypto),
	ok= application:start(mnesia),
	ok = application:start(openacd),
	erlctl:format("Started!~n"),
	ok.

stop(not_running, _) ->
	{error, 1, "Not running"};
stop(running, _) ->
	erlctl:format("Stopping OpenACD...~n"),
	application:stop(openacd),
	erlctl:server_exit(),
	{ok, "Stopped"}.

restart(not_running, Opt) ->
	start(not_running, Opt);
restart(running, Opt) ->
	stop(running, Opt),
	{restart, [], "Restarting..."};
restart(started, Opt) ->
	start(started, Opt). % in context of application node

status(not_running, _) ->
	{ok, "Not Running"};
status(running, _) ->
	erlctl:format("Running "),
	openacd:uptime(),
	ok.

queue_status(not_running, _) ->
	{ok, "Not Running"};
queue_status(running, _) ->
	openacd:get_queue_status(),
	ok.

agent_status(not_running, _) ->
	{ok, "Not Running"};
agent_status(running, _) ->
	openacd:get_agent_status(),
	ok.
