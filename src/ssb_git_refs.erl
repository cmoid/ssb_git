%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% Ref index: what a repo's branches are, from its git-update messages.
%%
%% An ssb_view over ssb_store plus an ssb_plugin:
%%   git.refs({repo})   async -> {head, refs: [{name, hash}]}
%%   git.packs({repo})  async -> [{update, pack, idx?, size?, chunks?}],
%%                       oldest first
%%   git.updates({repo}) async -> [{key, links, refs}], the repo's own graph
%%
%% git.updates is what a pusher needs to link its update into the graph
%% (refsBranch, repoBranch): every object of the repo, git-repo message
%% included, with the links the fold sees and the refs it published.  The
%% helper computes the heads and links itself; the node only reports.
%%
%% The view stores what the fold needs and nothing it computes: one row
%% per git-repo and git-update message, holding its ssb_git_fold object
%% (links, refs as published, head, repoBranch), and a row per pack it
%% names.  The fold itself runs per request — a repo's updates are tens or
%% hundreds of rows, and folding on read means there is no derived ref
%% state to go stale when an old update arrives late, which on SSB they do.
%%
%% Objects are kept as term_to_binary: exact (floats, nulls, the published
%% order of refs, which the fold depends on) and opaque, with view_version
%% bumped if the object's shape changes.
%%
%% Packs are what fetch reads (git.packs).  Two
%% shapes exist on the network: parallel `packs`/`indexes` arrays, and —
%% once — `packs: [{pack, idx}]`.  22 early updates stored each object as
%% its own blob (`objects`); they are not indexed.
%%
%% A pack over the blob cap is published in pieces (ssb_git_push):
%% {link: <first piece>, size: <its size>, chunks: [<the rest>, ...]}, the
%% pack being their concatenation.  The rest are rows of git_pack_chunk.
-module(ssb_git_refs).

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
-export([repo_refs/1, repo_packs/1, repo_updates/1]).

-define(SCHEMA_VERSION, 2).
%% kind: 0 = the git-repo message, 1 = a git-update.  The fold wants the
%% repo first and then the updates newest first (ssb_git_fold, "ORDER
%% MATTERS"), which is exactly the index order.
-define(DDL,
        ["CREATE TABLE IF NOT EXISTS git_object("
         "  id     TEXT PRIMARY KEY,"
         "  repo   TEXT NOT NULL,"
         "  kind   INTEGER NOT NULL,"
         "  ts     NUMERIC NOT NULL DEFAULT 0,"
         "  obj    BLOB NOT NULL) WITHOUT ROWID;",
         "CREATE INDEX IF NOT EXISTS ix_git_object_repo"
         "  ON git_object(repo, kind, ts DESC, id);",
         "CREATE TABLE IF NOT EXISTS git_pack("
         "  update_id TEXT NOT NULL,"
         "  pos       INTEGER NOT NULL,"
         "  pack      TEXT NOT NULL,"
         "  idx       TEXT,"
         "  size      INTEGER,"
         "  PRIMARY KEY (update_id, pos)) WITHOUT ROWID;",
         %% a chunked pack's pieces after the first (git_pack.pack), n from 1
         "CREATE TABLE IF NOT EXISTS git_pack_chunk("
         "  update_id TEXT NOT NULL,"
         "  pos       INTEGER NOT NULL,"
         "  n         INTEGER NOT NULL,"
         "  blob      TEXT NOT NULL,"
         "  PRIMARY KEY (update_id, pos, n)) WITHOUT ROWID;"]).

-define(REPO, 0).
-define(UPDATE, 1).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% ssb_view callbacks (run in the view_manager process)
%%%===================================================================

%% 2: chunked packs (git_pack_chunk), refolded so updates that arrived
%% before it get their chunk rows.
view_version() -> 2.

view_load() ->
    case ssb_store:complete(?MODULE) of
        true  -> ok;
        false -> empty
    end.

view_reset() ->
    _ = ssb_store:clear_complete(?MODULE),
    _ = ssb_store:exec("DELETE FROM git_object;"),
    _ = ssb_store:exec("DELETE FROM git_pack;"),
    _ = ssb_store:exec("DELETE FROM git_pack_chunk;"),
    ok.

view_save() ->
    _ = ssb_store:mark_complete(?MODULE),
    ok.

%% Every row is a pure function of one message, so redelivery rewrites
%% the same values.
view_entry(#message{} = Msg) ->
    case rows(Msg) of
        {Object, Packs} ->
            catch ssb_store:write("INSERT OR REPLACE INTO git_object"
                                  "(id, repo, kind, ts, obj)"
                                  " VALUES(?1, ?2, ?3, ?4, ?5)", Object),
            [begin
                 catch ssb_store:write("INSERT OR REPLACE INTO git_pack"
                                       "(update_id, pos, pack, idx, size)"
                                       " VALUES(?1, ?2, ?3, ?4, ?5)", P),
                 [catch ssb_store:write("INSERT OR REPLACE INTO git_pack_chunk"
                                        "(update_id, pos, n, blob)"
                                        " VALUES(?1, ?2, ?3, ?4)", [U, Pos, N, B])
                  || {N, B} <- lists:enumerate(Chunks)]
             end || {[U, Pos | _] = P, Chunks} <- Packs],
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
    [{[~"git", ~"refs"], async, owner},
     {[~"git", ~"packs"], async, owner},
     {[~"git", ~"updates"], async, owner}].

handle_rpc([~"git", ~"refs"], [{Opts}], _Caller) ->
    case ?pgv(~"repo", Opts) of
        Repo when is_binary(Repo) ->
            case repo_refs(Repo) of
                {ok, #{refs := Refs, head := Head}} ->
                    {reply, {[{~"head", Head},
                              {~"refs", [{[{~"name", N}, {~"hash", H}]}
                                         || {N, H} <- Refs]}]}};
                {error, not_found} ->
                    {error, ~"repo not found"}
            end;
        _ ->
            {error, ~"git.refs takes {repo}"}
    end;
handle_rpc([~"git", ~"refs"], _Args, _Caller) ->
    {error, ~"git.refs takes {repo}"};
handle_rpc([~"git", ~"packs"], [{Opts}], _Caller) ->
    case ?pgv(~"repo", Opts) of
        Repo when is_binary(Repo) ->
            case repo_packs(Repo) of
                {ok, Packs}        -> {reply, [pack_json(P) || P <- Packs]};
                {error, not_found} -> {error, ~"repo not found"}
            end;
        _ ->
            {error, ~"git.packs takes {repo}"}
    end;
handle_rpc([~"git", ~"packs"], _Args, _Caller) ->
    {error, ~"git.packs takes {repo}"};
handle_rpc([~"git", ~"updates"], [{Opts}], _Caller) ->
    case ?pgv(~"repo", Opts) of
        Repo when is_binary(Repo) ->
            case repo_updates(Repo) of
                {ok, Objs}         -> {reply, [update_json(O) || O <- Objs]};
                {error, not_found} -> {error, ~"repo not found"}
            end;
        _ ->
            {error, ~"git.updates takes {repo}"}
    end;
handle_rpc([~"git", ~"updates"], _Args, _Caller) ->
    {error, ~"git.updates takes {repo}"}.

%% refs as [[name, hash|null]], keeping the published order.
update_json(#{key := Key, links := Links, refs := Refs}) ->
    {[{~"key", Key}, {~"links", Links}, {~"refs", [[N, H] || {N, H} <- Refs]}]}.

%% Absent idx, size and chunks are omitted rather than sent as null.
pack_json({Update, Pack, Idx, Size, Chunks}) ->
    {[{~"update", Update}, {~"pack", Pack}]
     ++ [{~"idx", Idx} || is_binary(Idx)]
     ++ [{~"size", Size} || is_integer(Size)]
     ++ [{~"chunks", Chunks} || Chunks =/= []]}.

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

ensure_registered(State) ->
    case ssb_view:ensure_registered(?MODULE) of
        ok    -> ok;
        retry -> erlang:send_after(2000, self(), ensure_registered)
    end,
    {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Reads
%%%===================================================================

%% A repo's refs, its own followed by those inherited from its upstream
%% chain (unique by name), and its own HEAD.
repo_refs(Repo) ->
    case own(Repo) of
        {ok, #{head := Head} = Own} ->
            Chain = upstreams(Repo, #{Repo => true}),
            Ups = [U || {ok, U} <- [own(R) || R <- Chain]],
            {ok, (ssb_git_fold:refs(Own, Ups))#{head => Head}};
        Err ->
            Err
    end.

own(Repo) ->
    case repo_updates(Repo) of
        {ok, Objs} -> {ok, ssb_git_fold:fold(Objs)};
        Err        -> Err
    end.

%% The repo's own fold objects, in fold order: the git-repo message, then
%% its updates newest first.
repo_updates(Repo) ->
    Objs = [binary_to_term(B)
            || [B] <- q("SELECT obj FROM git_object WHERE repo=?1"
                        " ORDER BY kind, ts DESC, id", [Repo])],
    case Objs of
        [#{key := Repo} | _] -> {ok, Objs};
        _                    -> {error, not_found}
    end.

%% Every pack a clone of Repo needs: its own and its upstream chain's,
%% the same repos repo_refs folds.  Oldest update first, so that a thin
%% pack's bases (if any pusher ever wrote one) arrive before it; the
%% helper copes with the order being wrong anyway.
repo_packs(Repo) ->
    case q("SELECT 1 FROM git_object WHERE id=?1 AND kind=?2", [Repo, ?REPO]) of
        [_] ->
            Repos = [Repo | upstreams(Repo, #{Repo => true})],
            Rows = lists:append(
                     [q("SELECT o.ts, p.update_id, p.pos, p.pack, p.idx, p.size"
                        " FROM git_pack p JOIN git_object o ON o.id = p.update_id"
                        " WHERE o.repo=?1", [R]) || R <- Repos]),
            {ok, [{U, P, I, S, chunks(U, Pos)}
                  || [_, U, Pos, P, I, S] <- lists:sort(Rows)]};
        _ ->
            {error, not_found}
    end.

chunks(Update, Pos) ->
    [B || [B] <- q("SELECT blob FROM git_pack_chunk WHERE update_id=?1"
                   " AND pos=?2 ORDER BY n", [Update, Pos])].

%% A fork's upstream, its upstream's, ..., stopping at a cycle or a repo
%% this node does not hold.  Read from ssb_git_repos's table.
upstreams(Repo, Seen) ->
    case q("SELECT upstream FROM git_repo WHERE id=?1", [Repo]) of
        [[Up]] when is_binary(Up), not is_map_key(Up, Seen) ->
            [Up | upstreams(Up, Seen#{Up => true})];
        _ ->
            []
    end.

q(Sql, Params) ->
    try ssb_store:q(Sql, Params) of
        L when is_list(L) -> L;
        _                 -> []
    catch _:_ -> []          %% store down: no index, never a crash
    end.

%%%===================================================================
%%% Rows
%%%===================================================================

%% {ObjectRow, [{PackRow, Chunks}]} for a public git-repo or git-update,
%% skip otherwise.
rows(#message{id = Id, timestamp = Ts, content = {Props}} = Msg)
  when is_binary(Id) ->
    case {?pgv(~"type", Props), ?pgv(~"repo", Props)} of
        {~"git-repo", _} ->
            {[Id, Id, ?REPO, num(Ts), obj(Msg)], []};
        {~"git-update", Repo} when is_binary(Repo) ->
            {[Id, Repo, ?UPDATE, num(Ts), obj(Msg)], pack_rows(Id, Props)};
        _ ->
            skip
    end;
rows(_) ->
    skip.

obj(Msg) ->
    term_to_binary(ssb_git_fold:object(Msg)).

num(N) when is_number(N) -> N;
num(_)                   -> 0.

pack_rows(Id, Props) ->
    Packs = list_or_empty(?pgv(~"packs", Props)),
    Idxs  = list_or_empty(?pgv(~"indexes", Props)),
    Pairs = lists:zip(Packs, pad(Idxs, length(Packs)), trim),
    [{[Id, Pos, Pack, Idx, Size], Chunks}
     || {Pos, {P, I}} <- lists:enumerate(0, Pairs),
        {Pack, Idx, Size, Chunks} <- [pack_links(P, I)],
        is_binary(Pack)].

%% {link, size} with a parallel index entry, or the {pack, idx} variant.
pack_links({PProps}, I) ->
    case ?pgv(~"pack", PProps) of
        {Pack} ->
            {Idx} = case ?pgv(~"idx", PProps) of {_} = X -> X; _ -> {[]} end,
            {blob_id(?pgv(~"link", Pack)), blob_id(?pgv(~"link", Idx)),
             size_or_null(?pgv(~"size", Pack)), chunk_ids(Pack)};
        _ ->
            Idx = case I of {IProps} -> blob_id(?pgv(~"link", IProps)); _ -> null end,
            {blob_id(?pgv(~"link", PProps)), Idx, size_or_null(?pgv(~"size", PProps)),
             chunk_ids(PProps)}
    end;
pack_links(_, _) ->
    {null, null, null, []}.

%% The pieces after the first, all or nothing: a pack with one bad piece
%% id cannot be put back together, and reading it as unchunked would hand
%% index-pack a truncated pack, so it is kept with a marker that fails
%% loudly at fetch rather than quietly.
chunk_ids(Props) ->
    case ?pgv(~"chunks", Props) of
        L when is_list(L), L =/= [] ->
            Ids = [blob_id(B) || B <- L],
            case lists:member(null, Ids) of
                true  -> [~"bad-chunk-list"];
                false -> Ids
            end;
        _ ->
            []
    end.

blob_id(<<"&", _/binary>> = B) -> B;
blob_id(_)                     -> null.

size_or_null(N) when is_integer(N), N >= 0 -> N;
size_or_null(_)                    -> null.

list_or_empty(L) when is_list(L) -> L;
list_or_empty(_)                 -> [].

pad(L, N) when length(L) >= N -> L;
pad(L, N)                     -> L ++ lists:duplicate(N - length(L), null).

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

update(Content) ->
    #message{id = ~"%u", author = ~"@a", sequence = 3, timestamp = 1000,
             previous = ~"%p", content = {[{~"type", ~"git-update"},
                                           {~"repo", ~"%r"} | Content]}}.

rows_test_() ->
    Parallel = update([{~"packs",   [{[{~"link", ~"&p0"}, {~"size", 10}]},
                                     {[{~"link", ~"&p1"}, {~"size", 20}]}]},
                       {~"indexes", [{[{~"link", ~"&i0"}]},
                                     {[{~"link", ~"&i1"}]}]}]),
    Paired = update([{~"packs", [{[{~"pack", {[{~"link", ~"&p"}, {~"size", 5}]}},
                                   {~"idx",  {[{~"link", ~"&i"}]}}]}]}]),
    Chunked = update([{~"packs", [{[{~"link", ~"&p"}, {~"size", 4},
                                    {~"chunks", [~"&c1", ~"&c2"]}]}]}]),
    [?_assertMatch({[~"%u", ~"%r", ?UPDATE, 1000, _],
                    [{[~"%u", 0, ~"&p0", ~"&i0", 10], []},
                     {[~"%u", 1, ~"&p1", ~"&i1", 20], []}]}, rows(Parallel)),
     ?_assertMatch({_, [{[~"%u", 0, ~"&p", ~"&i", 5], []}]}, rows(Paired)),
     ?_assertMatch({_, [{[~"%u", 0, ~"&p", null, 4], [~"&c1", ~"&c2"]}]},
                   rows(Chunked)),
     %% a chunk list with a non-blob in it is kept, marked, not dropped
     ?_assertMatch({_, [{_, [~"bad-chunk-list"]}]},
                   rows(update([{~"packs", [{[{~"link", ~"&p"},
                                              {~"chunks", [~"&c1", 7]}]}]}]))),
     %% a pack without an index entry keeps its pack
     ?_assertMatch({_, [{[~"%u", 0, ~"&p", null, null], []}]},
                   rows(update([{~"packs", [{[{~"link", ~"&p"}]}]}]))),
     %% the legacy per-object shape is not a pack
     ?_assertMatch({_, []},
                   rows(update([{~"objects", {[{~"abc", {[{~"link", ~"&o"}]}}]}}]))),
     ?_assertMatch({[~"%u", ~"%u", ?REPO, _, _], []},
                   rows((update([]))#message{content = {[{~"type", ~"git-repo"}]}})),
     %% an update with no repo, private content, other types
     ?_assertEqual(skip, rows((update([]))#message{
                                content = {[{~"type", ~"git-update"}]}})),
     ?_assertEqual(skip, rows((update([]))#message{content = ~"Ym94.box"})),
     ?_assertEqual(skip, rows((update([]))#message{
                                content = {[{~"type", ~"post"}]}}))].

%% The stored object is exactly the fold's object, and survives the trip.
object_roundtrip_test() ->
    Msg = update([{~"refs", {[{~"refs/heads/master", ~"abc"}]}}]),
    {[_, _, _, _, Bin], _} = rows(Msg),
    ?assertEqual(ssb_git_fold:object(Msg), binary_to_term(Bin)).

-endif.
