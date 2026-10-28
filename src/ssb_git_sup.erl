%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
-module(ssb_git_sup).

-behaviour(supervisor).

-include_lib("ssb/include/ssb.hrl").

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [?CHILD(ssb_git_repos, worker),
           ?CHILD(ssb_git_refs, worker),
           ?CHILD(ssb_git_issues, worker)]}}.
