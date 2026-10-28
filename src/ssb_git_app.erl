%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
-module(ssb_git_app).

-behaviour(application).

-export([start/2, stop/1]).

%% Every module here is a view, and a view registers itself (plugin and
%% view both) from its own process once its tables are declared — see
%% ssb_git_repos:init/1.  Nothing to register before the supervisor.
%%
%% First, refuse to start at all on a node whose plugin API differs from
%% the one this app was compiled against.  The registries would refuse
%% each module anyway; checking here turns that into one error at start,
%% naming both versions, instead of a running app with no methods.
start(_StartType, _StartArgs) ->
    case check_api() of
        ok ->
            ssb_git_sup:start_link();
        {error, _} = Err ->
            logger:error("ssb_git not started: ~p", [Err]),
            Err
    end.

%% A node without ssb_plugin:check_app/1 predates the plugin API version
%% and cannot say whether our #message{} layout matches its own.
check_api() ->
    case erlang:function_exported(ssb_plugin, check_app, 1) of
        true  -> ssb_plugin:check_app(ssb_git);
        false -> {error, {plugin_api_mismatch,
                          #{module => ssb_git, node => unversioned}}}
    end.

%% There is no view_manager:unregister_view yet, so stopping this app
%% removes the methods but the view stays registered until the node
%% restarts (doc/research/git-over-ssb.md in erlbutt, "What has to be
%% fixed first").
stop(_State) ->
    plugin_registry:unregister_plugin(ssb_git_repos),
    plugin_registry:unregister_plugin(ssb_git_refs),
    plugin_registry:unregister_plugin(ssb_git_issues),
    ok.
