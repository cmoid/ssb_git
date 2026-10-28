%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% Issues and pull requests, as git-ssb published them.
%%
%%   {type: issue, project: <repo>, title?, text}
%%   {type: pull-request, repo: <repo>, project: <repo>, branch,
%%    head_repo, head_branch, title?, text}
%%
%% Their comments are ordinary posts with root: <issue>, so a thread view
%% shows them and nothing here indexes them.  What this does index is
%% state: whether each is open, and its title, changed by
%%
%%   {type: issue-edit, issues: [{link: <issue>, open?, title?}]}
%%   {type: issue-edit, issue: <issue>, title}            (early clients)
%%   {type: git-update, issues: [{link, open: false, merged?}]}
%%                                         (a push that fixes or merges it)
%%
%% WHOSE CHANGE COUNTS is the reader's policy: here, the issue's author and
%% the owner of the repo it is filed against (the git-repo message's
%% author).  Anyone may publish a close; one from anybody else is kept and
%% shown, marked as not counted, but does not change the state.  Among the
%% changes that count, the latest wins.  On one well-connected node in
%% October 2026, 278 of the 306 changes naming a known issue counted; the
%% other 28 were third parties'.
%%
%% An ssb_view over ssb_store, two tables, both pure functions of single
%% messages — so an edit that arrives before its issue is simply waiting
%% for it, and state is computed on read.  Plus an ssb_plugin:
%%   git.issues({repo, kind?, state?})  async -> issues and PRs, newest first
%%   git.issue({id})                    async -> one, with every change to it
-module(ssb_git_issues).

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
-export([issues/3, issue/1, open_counts/0]).

-define(SCHEMA_VERSION, 1).
-define(DDL,
        ["CREATE TABLE IF NOT EXISTS git_issue("
         "  id          TEXT PRIMARY KEY,"
         "  repo        TEXT NOT NULL,"
         "  kind        INTEGER NOT NULL,"   %% 0 issue, 1 pull request
         "  author      TEXT NOT NULL,"
         "  ts          NUMERIC NOT NULL DEFAULT 0,"
         "  title       TEXT,"               %% its title, else its first line
         "  branch      TEXT,"
         "  head_repo   TEXT,"
         "  head_branch TEXT) WITHOUT ROWID;",
         "CREATE INDEX IF NOT EXISTS ix_git_issue_repo"
         "  ON git_issue(repo, kind, ts);",
         "CREATE TABLE IF NOT EXISTS git_issue_edit("
         "  msg     TEXT NOT NULL,"
         "  issue   TEXT NOT NULL,"
         "  author  TEXT NOT NULL,"
         "  ts      NUMERIC NOT NULL DEFAULT 0,"
         "  open    INTEGER,"                %% 1, 0, or NULL: not a state change
         "  title   TEXT,"
         "  merged  INTEGER,"
         "  PRIMARY KEY (msg, issue)) WITHOUT ROWID;",
         "CREATE INDEX IF NOT EXISTS ix_git_issue_edit_issue"
         "  ON git_issue_edit(issue, ts);"]).

-define(ISSUE, 0).
-define(PR, 1).
%% a title longer than this is a paragraph someone left without a newline
-define(TITLE_MAX, 200).

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
    _ = ssb_store:exec("DELETE FROM git_issue;"),
    _ = ssb_store:exec("DELETE FROM git_issue_edit;"),
    ok.

view_save() ->
    _ = ssb_store:mark_complete(?MODULE),
    ok.

view_entry(#message{} = Msg) ->
    {Issues, Edits} = rows(Msg),
    [catch ssb_store:write("INSERT OR REPLACE INTO git_issue"
                           "(id, repo, kind, author, ts, title, branch,"
                           " head_repo, head_branch)"
                           " VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)", R)
     || R <- Issues],
    [catch ssb_store:write("INSERT OR REPLACE INTO git_issue_edit"
                           "(msg, issue, author, ts, open, title, merged)"
                           " VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)", R)
     || R <- Edits],
    ok;
view_entry(_) ->
    ok.

%%%===================================================================
%%% ssb_plugin callbacks
%%%===================================================================

manifest() ->
    [{[~"git", ~"issues"], async, owner},
     {[~"git", ~"issue"], async, owner}].

handle_rpc([~"git", ~"issues"], [{Opts}], _Caller) ->
    Kind = case ?pgv(~"kind", Opts) of
               ~"issue"        -> issue;
               ~"pull-request" -> pull_request;
               _               -> all
           end,
    State = case ?pgv(~"state", Opts) of
                ~"closed" -> closed;
                ~"all"    -> all;
                _         -> open
            end,
    case ?pgv(~"repo", Opts) of
        Repo when is_binary(Repo) ->
            {reply, [to_json(I) || I <- issues(Repo, Kind, State)]};
        _ ->
            {error, ~"git.issues takes {repo, kind?, state?}"}
    end;
handle_rpc([~"git", ~"issue"], [{Opts}], _Caller) ->
    case issue(?pgv(~"id", Opts)) of
        {ok, I}            -> {reply, to_json(I)};
        {error, not_found} -> {error, ~"issue not found"}
    end;
handle_rpc([~"git", Method], _Args, _Caller) ->
    {error, <<"git.", Method/binary, ": bad arguments">>}.

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

%% A repo's issues and/or pull requests, newest first.
%% Kind: issue | pull_request | all; State: open | closed | all.
issues(Repo, Kind, State) ->
    KindSql = case Kind of
                  issue        -> " AND kind=0";
                  pull_request -> " AND kind=1";
                  all          -> ""
              end,
    Owner = owner(Repo),
    All = [with_state(row_map(R), Owner)
           || R <- q("SELECT id, repo, kind, author, ts, title, branch, head_repo,"
                     " head_branch FROM git_issue WHERE repo=?1" ++ KindSql ++
                     " ORDER BY ts DESC, id", [Repo])],
    [I || #{open := Open} = I <- All,
          State =:= all orelse (State =:= open) =:= Open].

%% #{Repo => {OpenIssues, OpenPullRequests}} for every repo with any, in
%% two queries however many repos there are: the repo list wants the
%% counts for all of them at once.
open_counts() ->
    Owners = maps:from_list([{R, A} || [R, A] <- q("SELECT id, author FROM git_repo", [])]),
    Edits = lists:foldl(
              fun([Iss, M, A, Ts, O, T, Mg], Acc) ->
                      E = #{msg => M, author => A, ts => Ts, open => bool(O),
                            title => T, merged => bool(Mg)},
                      maps:update_with(Iss, fun(L) -> [E | L] end, [E], Acc)
              end, #{},
              q("SELECT issue, msg, author, ts, open, title, merged"
                " FROM git_issue_edit ORDER BY ts DESC, msg DESC", [])),
    lists:foldl(
      fun([Id, Repo, Kind, Author], Acc) ->
              Owner = maps:get(Repo, Owners, undefined),
              Es = [E#{counted => A =:= Author orelse A =:= Owner}
                    || #{author := A} = E <- maps:get(Id, Edits, [])],
              case state(#{edits => Es, title => null}) of
                  #{open := true} ->
                      maps:update_with(Repo, fun({I, P}) -> bump(Kind, I, P) end,
                                       bump(Kind, 0, 0), Acc);
                  _ ->
                      Acc
              end
      end, #{}, q("SELECT id, repo, kind, author FROM git_issue", [])).

bump(?PR, I, P) -> {I, P + 1};
bump(_, I, P)   -> {I + 1, P}.

%% One issue or pull request, with every change anyone published to it.
issue(Id) when is_binary(Id) ->
    case q("SELECT id, repo, kind, author, ts, title, branch, head_repo,"
           " head_branch FROM git_issue WHERE id=?1", [Id]) of
        [R] ->
            #{repo := Repo} = I = row_map(R),
            {ok, with_state(I, owner(Repo))};
        _ ->
            {error, not_found}
    end;
issue(_) ->
    {error, not_found}.

row_map([Id, Repo, Kind, Author, Ts, Title, Branch, HeadRepo, HeadBranch]) ->
    #{id => Id, repo => Repo,
      kind => case Kind of ?PR -> pull_request; _ -> issue end,
      author => Author, ts => Ts, title => Title,
      branch => Branch, head_repo => HeadRepo, head_branch => HeadBranch}.

%% Fold its changes into an issue: open, title, merged, and the list of
%% changes each marked counted or not.
with_state(#{id := Id, author := Author} = I, Owner) ->
    Edits = [#{msg => M, author => A, ts => Ts, open => bool(O),
               title => T, merged => bool(Mg),
               counted => A =:= Author orelse A =:= Owner}
             || [M, A, Ts, O, T, Mg]
                    <- q("SELECT msg, author, ts, open, title, merged"
                         " FROM git_issue_edit WHERE issue=?1"
                         " ORDER BY ts, msg", [Id])],
    state(I#{edits => Edits}).

%% Pure: the latest counted change of each kind wins.
state(#{edits := Edits, title := Title0} = I) ->
    Counted = [E || #{counted := true} = E <- Edits],
    Open = last([O || #{open := O} <- Counted, is_boolean(O)], true),
    Merged = last([M || #{open := false, merged := M} <- Counted, is_boolean(M)], false),
    Title = last([T || #{title := T} <- Counted, is_binary(T)], Title0),
    I#{open => Open, merged => Open =:= false andalso Merged, title => Title}.

last([], Default) -> Default;
last(L, _)        -> lists:last(L).

bool(1) -> true;
bool(0) -> false;
bool(_) -> undefined.

%% The repo's owner, if this node holds its git-repo message (from
%% ssb_git_repos's table).  Without it only the author's changes count.
owner(Repo) ->
    case q("SELECT author FROM git_repo WHERE id=?1", [Repo]) of
        [[A]] -> A;
        _     -> undefined
    end.

to_json(#{edits := Edits} = I) ->
    {[{~"id", maps:get(id, I)},
      {~"kind", case maps:get(kind, I) of issue -> ~"issue"; _ -> ~"pull-request" end},
      {~"repo", maps:get(repo, I)},
      {~"author", maps:get(author, I)},
      {~"ts", maps:get(ts, I)},
      {~"open", maps:get(open, I)},
      {~"merged", maps:get(merged, I)}]
     ++ [{K, V} || {K, F} <- [{~"title", title}, {~"branch", branch},
                              {~"head_repo", head_repo},
                              {~"head_branch", head_branch}],
                   V <- [maps:get(F, I)], is_binary(V)]
     ++ [{~"edits", [{[{~"msg", M}, {~"author", A}, {~"ts", Ts},
                       {~"counted", C}]
                      ++ [{~"open", O} || is_boolean(O)]
                      ++ [{~"title", T} || is_binary(T)]
                      ++ [{~"merged", Mg} || is_boolean(Mg)]}
                     || #{msg := M, author := A, ts := Ts, counted := C,
                          open := O, title := T, merged := Mg} <- Edits]}]}.

q(Sql, Params) ->
    try ssb_store:q(Sql, Params) of
        L when is_list(L) -> L;
        _                 -> []
    catch _:_ -> []          %% store down: no index, never a crash
    end.

%%%===================================================================
%%% Rows
%%%===================================================================

%% {[IssueRow], [EditRow]} for one message.
rows(#message{id = Id, author = Author, timestamp = Ts, received = Recv,
              content = {Props}}) when is_binary(Id), is_binary(Author) ->
    T = sort_ts(Ts, Recv),
    case ?pgv(~"type", Props) of
        ~"issue" ->
            case msg_id(?pgv(~"project", Props)) of
                null -> {[], []};
                Repo -> {[[Id, Repo, ?ISSUE, Author, T, title(Props),
                           null, null, null]], []}
            end;
        ~"pull-request" ->
            case msg_id(first_binary([?pgv(~"repo", Props), ?pgv(~"project", Props)])) of
                null -> {[], []};
                Repo -> {[[Id, Repo, ?PR, Author, T, title(Props),
                           text_or_null(?pgv(~"branch", Props)),
                           msg_id(?pgv(~"head_repo", Props)),
                           text_or_null(?pgv(~"head_branch", Props))]], []}
            end;
        ~"issue-edit" ->
            Listed = edits(Id, Author, T, ?pgv(~"issues", Props)),
            %% the early form: one retitle, outside any list
            Early = case {msg_id(?pgv(~"issue", Props)), text_or_null(?pgv(~"title", Props))} of
                        {null, _}      -> [];
                        {_, null}      -> [];
                        {Issue, Title} -> [[Id, Issue, Author, T, null, Title, null]]
                    end,
            {[], unique_issue(Listed ++ Early)};
        ~"git-update" ->
            {[], edits(Id, Author, T, ?pgv(~"issues", Props))};
        _ ->
            {[], []}
    end;
rows(_) ->
    {[], []}.

%% One row per entry that names an issue and changes something.
edits(Msg, Author, Ts, List) when is_list(List) ->
    unique_issue(
      [[Msg, Issue, Author, Ts, Open, Title, Merged]
       || {E} <- List,
          Issue <- [msg_id(?pgv(~"link", E))], Issue =/= null,
          Open <- [int_bool(?pgv(~"open", E))],
          Title <- [text_or_null(?pgv(~"title", E))],
          Merged <- [int_bool(?pgv(~"merged", E))],
          Open =/= null orelse Title =/= null]);
edits(_, _, _, _) ->
    [].

%% A message that names an issue twice keeps the first: the table's key
%% is (msg, issue), and INSERT OR REPLACE would otherwise keep the last.
unique_issue(Rows) ->
    lists:reverse(
      lists:foldl(fun([_, Issue | _] = R, Acc) ->
                          case lists:any(fun([_, I | _]) -> I =:= Issue end, Acc) of
                              true  -> Acc;
                              false -> [R | Acc]
                          end
                  end, [], Rows)).

%% Its title, else the first non-blank line of its text, trimmed of a
%% leading markdown heading mark.
title(Props) ->
    case text_or_null(?pgv(~"title", Props)) of
        null ->
            case ?pgv(~"text", Props) of
                Text when is_binary(Text) -> first_line(Text);
                _                         -> null
            end;
        Title ->
            clip(Title)
    end.

first_line(Text) ->
    Lines = [string:trim(L) || L <- binary:split(Text, [<<"\n">>, <<"\r">>], [global])],
    case [L || L <- Lines, L =/= <<>>] of
        []        -> null;
        [Line | _] -> clip(string:trim(Line, leading, "# "))
    end.

clip(B) ->
    case string:length(B) > ?TITLE_MAX of
        true  -> unicode:characters_to_binary([string:slice(B, 0, ?TITLE_MAX), "…"]);
        false -> B
    end.

first_binary(L) ->
    case [B || B <- L, is_binary(B)] of
        [B | _] -> B;
        []      -> null
    end.

int_bool(true)  -> 1;
int_bool(false) -> 0;
int_bool(_)     -> null.

text_or_null(B) when is_binary(B), B =/= <<>> -> B;
text_or_null(_)                                -> null.

msg_id(<<"%", _/binary>> = B) ->
    case binary:longest_common_suffix([B, ~".sha256"]) of
        7 -> B;
        _ -> null
    end;
msg_id(_) ->
    null.

%% min(claimed, received), as ssb_git_repos does and for the same reason.
sort_ts(Ts, Recv) ->
    case {num(Ts), num(Recv)} of
        {undefined, undefined} -> 0;
        {undefined, R}         -> R;
        {T, undefined}         -> T;
        {T, R}                 -> min(T, R)
    end.

num(N) when is_integer(N) -> N;
num(N) when is_float(N)   -> trunc(N);
num(_)                    -> undefined.

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

-define(REPO, ~"%repo0000000000000000000000000000000000000000=.sha256").
-define(ISS,  ~"%issue000000000000000000000000000000000000000=.sha256").

msg(Id, Author, Ts, Content) ->
    #message{id = Id, author = Author, timestamp = Ts, received = Ts + 5,
             content = {Content}}.

issue_rows_test_() ->
    [?_assertEqual({[[~"%i", ?REPO, ?ISSUE, ~"@a", 10, ~"It breaks", null, null, null]], []},
                   rows(msg(~"%i", ~"@a", 10, [{~"type", ~"issue"}, {~"project", ?REPO},
                                              {~"text", ~"\n# It breaks\n\nwhen I..."}]))),
     %% an explicit title wins over the text
     ?_assertMatch({[[_, _, _, _, _, ~"Title", _, _, _]], []},
                   rows(msg(~"%i", ~"@a", 10, [{~"type", ~"issue"}, {~"project", ?REPO},
                                              {~"title", ~"Title"}, {~"text", ~"body"}]))),
     ?_assertEqual({[[~"%p", ?REPO, ?PR, ~"@b", 10, ~"merge this", ~"master", ?ISS, ~"test"]], []},
                   rows(msg(~"%p", ~"@b", 10,
                            [{~"type", ~"pull-request"}, {~"repo", ?REPO},
                             {~"project", ?REPO}, {~"branch", ~"master"},
                             {~"head_repo", ?ISS}, {~"head_branch", ~"test"},
                             {~"text", ~"merge this"}]))),
     %% no repo, or not a message id: not indexed
     ?_assertEqual({[], []}, rows(msg(~"%i", ~"@a", 10, [{~"type", ~"issue"},
                                                       {~"text", ~"x"}]))),
     ?_assertEqual({[], []}, rows(msg(~"%i", ~"@a", 10, [{~"type", ~"issue"},
                                                       {~"project", ~"@feed"}])))].

edit_rows_test_() ->
    Close = [{~"link", ?ISS}, {~"open", false}],
    [?_assertEqual({[], [[~"%e", ?ISS, ~"@a", 10, 0, null, null]]},
                   rows(msg(~"%e", ~"@a", 10, [{~"type", ~"issue-edit"},
                                              {~"issues", [{Close}]}]))),
     %% the early retitle form
     ?_assertEqual({[], [[~"%e", ?ISS, ~"@a", 10, null, ~"New", null]]},
                   rows(msg(~"%e", ~"@a", 10, [{~"type", ~"issue-edit"},
                                              {~"issue", ?ISS}, {~"title", ~"New"}]))),
     %% a push closing (and merging) what it fixes
     ?_assertEqual({[], [[~"%u", ?ISS, ~"@a", 10, 0, null, 1]]},
                   rows(msg(~"%u", ~"@a", 10, [{~"type", ~"git-update"},
                                              {~"issues", [{[{~"merged", true} | Close]}]}]))),
     %% an entry that changes nothing, or names nothing, is not an edit
     ?_assertEqual({[], []},
                   rows(msg(~"%e", ~"@a", 10, [{~"type", ~"issue-edit"},
                                              {~"issues", [{[{~"link", ?ISS}]},
                                                           {[{~"open", false}]}]}]))),
     %% the same issue twice in one message: the first entry stands
     ?_assertMatch({[], [[_, ?ISS, _, _, 0, _, _]]},
                   rows(msg(~"%e", ~"@a", 10,
                            [{~"type", ~"issue-edit"},
                             {~"issues", [{Close}, {[{~"link", ?ISS}, {~"open", true}]}]}])))].

edit(A, Ts, Open, Counted) ->
    #{msg => integer_to_binary(Ts), author => A, ts => Ts, open => Open,
      title => undefined, merged => undefined, counted => Counted}.

state_test_() ->
    Base = #{title => ~"T"},
    [%% no changes: open
     ?_assertMatch(#{open := true, merged := false}, state(Base#{edits => []})),
     %% the latest counted change wins
     ?_assertMatch(#{open := true},
                   state(Base#{edits => [edit(~"@a", 1, false, true),
                                         edit(~"@a", 2, true, true)]})),
     %% a third party's close is kept but does not count
     ?_assertMatch(#{open := true, edits := [_]},
                   state(Base#{edits => [edit(~"@x", 1, false, false)]})),
     %% merged only when it ends closed
     ?_assertMatch(#{open := false, merged := true},
                   state(Base#{edits => [(edit(~"@o", 1, false, true))#{merged => true}]})),
     ?_assertMatch(#{open := true, merged := false},
                   state(Base#{edits => [(edit(~"@o", 1, false, true))#{merged => true},
                                         edit(~"@a", 2, true, true)]})),
     %% a counted retitle replaces the title; an uncounted one does not
     ?_assertMatch(#{title := ~"New"},
                   state(Base#{edits => [(edit(~"@a", 1, undefined, true))#{title => ~"New"}]})),
     ?_assertMatch(#{title := ~"T"},
                   state(Base#{edits => [(edit(~"@x", 1, undefined, false))#{title => ~"New"}]}))].

title_test_() ->
    Long = binary:copy(~"x", ?TITLE_MAX + 10),
    [?_assertEqual(~"first", title([{~"text", ~"  \n\n first \nsecond"}])),
     ?_assertEqual(null, title([{~"text", ~"\n  \n"}])),
     ?_assertEqual(null, title([])),
     ?_assertEqual(?TITLE_MAX + 1, string:length(title([{~"text", Long}])))].

-endif.
