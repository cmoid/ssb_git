%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% Repo index: every git-ssb repository the node holds.  A repo is a
%% public `git-repo` message — {type: git-repo, name?, upstream?} — and its
%% message id is the repo's identity and its clone URL (ssb://%id).  A fork
%% is a git-repo whose `upstream` names the repo it was forked from.
%%
%% An ssb_view over ssb_store — a row per repo — plus an ssb_plugin:
%%   git.repos({author?})   source -> repos, oldest first
%%
%% This is the first table of the ssb_git view (erlbutt
%% doc/research/git-over-ssb.md, "The ssb_git app"); pushes, refs and packs
%% come next, in their own tables.
%%
%% Private repos (git-repo with recps) arrive as encrypted content with no
%% visible type and are not indexed.
-module(ssb_git_repos).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).
-behaviour(ssb_view).
-behaviour(ssb_plugin).

-include_lib("ssb/include/ssb.hrl").

-export([start_link/0]).
-export([view_version/0, view_load/0, view_reset/0, view_save/0, view_entry/1]).
-export([manifest/0, handle_rpc/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2,
         handle_info/2, terminate/2, code_change/3]).

-define(SCHEMA_VERSION, 1).
-define(DDL,
        ["CREATE TABLE IF NOT EXISTS git_repo("
         "  id       TEXT PRIMARY KEY,"
         "  author   TEXT NOT NULL,"
         "  name     TEXT,"
         "  upstream TEXT,"
         "  ts       INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;",
         "CREATE INDEX IF NOT EXISTS ix_git_repo_author"
         "  ON git_repo(author, ts);"]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% ssb_view callbacks (run in the view_manager process)
%%%===================================================================

view_version() -> 1.

view_load() ->
    case ssb_store:complete(?MODULE) of
        true  -> ok;
        false -> empty
    end.

view_reset() ->
    _ = ssb_store:clear_complete(?MODULE),
    _ = ssb_store:exec("DELETE FROM git_repo;"),
    ok.

view_save() ->
    _ = ssb_store:mark_complete(?MODULE),
    ok.

%% A repo row is written once and never changes: a git-repo message is
%% the whole of the repo's identity, and renames are not part of git-ssb.
%% Redelivery is harmless (DO NOTHING on the primary key).
view_entry(#message{} = Msg) ->
    case repo_row(Msg) of
        {ok, Row} ->
            catch ssb_store:write("INSERT INTO git_repo"
                                  "(id, author, name, upstream, ts)"
                                  " VALUES(?1, ?2, ?3, ?4, ?5)"
                                  " ON CONFLICT(id) DO NOTHING", Row),
            ok;
        skip ->
            ok
    end;
view_entry(_) ->
    ok.

%%%===================================================================
%%% ssb_plugin callbacks
%%%===================================================================

manifest() ->
    [{[~"git", ~"repos"], source, owner}].

handle_rpc([~"git", ~"repos"], Args, _Caller) ->
    Author = case Args of
                 [{Opts}] -> ?pgv(~"author", Opts);
                 _        -> undefined
             end,
    {source, [repo_json(R) || R <- repos(Author)]}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ok = ssb_store:declare(?MODULE, ?SCHEMA_VERSION, ?DDL),
    {ok, #{}, {continue, register}}.

handle_continue(register, State) ->
    ensure_registered(State).

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(ensure_registered, State) ->
    ensure_registered(State);
handle_info(_Info, State) ->
    {noreply, State}.

%% Registration failures are loud, transient ones retried on a timer —
%% the same pattern as every view in erlbutt (ssb_view:ensure_registered).
ensure_registered(State) ->
    case ssb_view:ensure_registered(?MODULE) of
        ok    -> ok;
        retry -> erlang:send_after(2000, self(), ensure_registered)
    end,
    {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

%% [Id, Author, Name, Upstream, Ts] for a git-repo message, skip otherwise.
%% name and upstream are optional and kept only when they are the right
%% shape; a malformed upstream is dropped rather than the whole repo.
repo_row(#message{id = Id, author = Author, timestamp = Ts,
                  received = Recv, content = {Props}})
  when is_binary(Id), is_binary(Author) ->
    case ?pgv(~"type", Props) of
        ~"git-repo" ->
            {ok, [Id, Author,
                  text_or_null(?pgv(~"name", Props)),
                  msg_id_or_null(?pgv(~"upstream", Props)),
                  sort_ts(Ts, Recv)]};
        _ ->
            skip
    end;
repo_row(_) ->
    skip.

text_or_null(B) when is_binary(B), B =/= <<>> -> B;
text_or_null(_)                                -> null.

msg_id_or_null(<<"%", _/binary>> = B) ->
    case binary:longest_common_suffix([B, ~".sha256"]) of
        7 -> B;
        _ -> null
    end;
msg_id_or_null(_) ->
    null.

%% min(claimed, received), as silkpurse_threads does and for the same
%% reason: an author's clock is unvalidated, our own receipt time is not.
sort_ts(Ts, Recv) ->
    case {num_or_undefined(Ts), num_or_undefined(Recv)} of
        {undefined, undefined} -> 0;
        {undefined, R}         -> R;
        {T, undefined}         -> T;
        {T, R}                 -> min(T, R)
    end.

num_or_undefined(N) when is_integer(N) -> N;
num_or_undefined(N) when is_float(N)   -> trunc(N);
num_or_undefined(_)                    -> undefined.

repos(Author) when is_binary(Author) ->
    rows("SELECT id, author, name, upstream, ts FROM git_repo"
         " WHERE author=?1 ORDER BY ts", [Author]);
repos(_) ->
    rows("SELECT id, author, name, upstream, ts FROM git_repo"
         " ORDER BY ts", []).

%% Absent fields are omitted rather than sent as null.
repo_json([Id, Author, Name, Upstream, Ts]) ->
    {[{~"id", Id}, {~"author", Author}]
     ++ [{~"name", Name} || is_binary(Name)]
     ++ [{~"upstream", Upstream} || is_binary(Upstream)]
     ++ [{~"ts", Ts}]}.

rows(Sql, Params) ->
    try ssb_store:q(Sql, Params) of
        L when is_list(L) -> L;
        _                 -> []
    catch _:_ -> []          %% store down: no index, never a crash
    end.

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

-define(REPO_ID, ~"%n92DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU=.sha256").
-define(AUTHOR,  ~"@EMovhfIrFk4NihAKnRNhrfRaqIhBv1Wj8pTxJNgvCCY=.ed25519").

msg(Content) ->
    #message{id = ?REPO_ID, author = ?AUTHOR, timestamp = 2000,
             received = 3000, content = Content}.

repo_row_test_() ->
    [?_assertEqual({ok, [?REPO_ID, ?AUTHOR, ~"git-ssb", null, 2000]},
                   repo_row(msg({[{~"type", ~"git-repo"},
                                  {~"name", ~"git-ssb"}]}))),
     %% a fork keeps its upstream
     ?_assertMatch({ok, [_, _, null, ?REPO_ID, _]},
                   repo_row(msg({[{~"type", ~"git-repo"},
                                  {~"upstream", ?REPO_ID}]}))),
     %% a malformed upstream or name is dropped, the repo is not
     ?_assertMatch({ok, [_, _, null, null, _]},
                   repo_row(msg({[{~"type", ~"git-repo"},
                                  {~"name", 42},
                                  {~"upstream", ~"not-an-id"}]}))),
     %% other types, and private (still-encrypted) content, are skipped
     ?_assertEqual(skip, repo_row(msg({[{~"type", ~"git-update"}]}))),
     ?_assertEqual(skip, repo_row(msg(~"c2VjcmV0.box"))),
     ?_assertEqual(skip, repo_row(not_a_message))].

sort_ts_test_() ->
    [?_assertEqual(2000, sort_ts(2000, 3000)),
     ?_assertEqual(3000, sort_ts(9999999, 3000)),   %% a clock from the future
     ?_assertEqual(3000, sort_ts(undefined, 3000)),
     ?_assertEqual(2000, sort_ts(2000.7, undefined)),
     ?_assertEqual(0,    sort_ts(~"yesterday", null))].

repo_json_test() ->
    ?assertEqual({[{~"id", ?REPO_ID}, {~"author", ?AUTHOR},
                   {~"name", ~"x"}, {~"ts", 5}]},
                 repo_json([?REPO_ID, ?AUTHOR, ~"x", null, 5])).

-endif.
