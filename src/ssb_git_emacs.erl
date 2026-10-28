%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% The node side of elisp/ssb-git.el.
%%
%% Emacs reaches the node over Erlang distribution (Distel, through
%% maxbutt's connection) and calls these functions directly, inside the
%% node; the muxrpc methods are for clients outside it.  Each returns
%% terms Distel's erlext carries well: maps with atom keys (hash tables
%% in elisp), binaries (strings), and the atom nil for anything absent.
%%
%% Profile names come from the core ssb_feed_meta view, as maxbutt's do.
-module(ssb_git_emacs).

-include_lib("ssb/include/ssb.hrl").

-export([repos/1, repo/1, issues/3, issue/1,
         new_issue/3, new_pull_request/6, set_open/2, comment/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Updates shown in a repo buffer.
-define(RECENT_UPDATES, 30).

%%%===================================================================
%%% Reads
%%%===================================================================

%% Every repo the node knows, most recently pushed (or created) first.
%% Which: all | mine.
repos(Which) ->
    Rows = case Which of
               mine -> q("SELECT id, author, name, upstream, ts FROM git_repo"
                         " WHERE author=?1", [keys:pub_key_disp()]);
               _    -> q("SELECT id, author, name, upstream, ts FROM git_repo", [])
           end,
    Pushed = maps:from_list(
               [{R, T} || [R, T] <- q("SELECT repo, max(ts) FROM git_object"
                                       " WHERE kind=1 GROUP BY repo", [])]),
    Open = ssb_git_issues:open_counts(),
    Repos = [begin
                 {OI, OP} = maps:get(Id, Open, {0, 0}),
                 #{id => Id, name => absent(Name), author => Author,
                   author_name => name(Author), upstream => absent(Up),
                   created => Ts, pushed => maps:get(Id, Pushed, nil),
                   open_issues => OI, open_prs => OP}
             end || [Id, Author, Name, Up, Ts] <- Rows],
    lists:sort(fun(A, B) -> activity(A) >= activity(B) end, Repos).

activity(#{pushed := nil, created := C}) -> C;
activity(#{pushed := P})                 -> P.

%% One repo: who made it, its branches (conflict branches marked with the
%% plain name they compete for), and its recent pushes, newest first,
%% summarised from their own messages so nothing is fetched.
repo(Id) when is_binary(Id) ->
    case q("SELECT author, name, upstream, ts FROM git_repo WHERE id=?1", [Id]) of
        [[Author, Name, Up, Ts]] ->
            {Head, Refs} = case ssb_git_refs:repo_refs(Id) of
                               {ok, #{head := H, refs := Rs}} -> {H, Rs};
                               _                              -> {nil, []}
                           end,
            {OI, OP} = maps:get(Id, ssb_git_issues:open_counts(), {0, 0}),
            {ok, #{id => Id, name => absent(Name), author => Author,
                   author_name => name(Author), upstream => absent(Up),
                   created => Ts, head => absent(Head),
                   refs => [#{name => N, hash => H,
                              conflict => case ssb_git_fold:realname(N) of
                                              {ok, Real} -> Real;
                                              error      -> nil
                                          end} || {N, H} <- Refs],
                   updates => recent_updates(Id),
                   open_issues => OI, open_prs => OP}};
        _ ->
            {error, not_found}
    end;
repo(_) ->
    {error, not_found}.

recent_updates(Repo) ->
    [U || [Key, _] <- q("SELECT id, ts FROM git_object WHERE repo=?1 AND kind=1"
                        " ORDER BY ts DESC, id LIMIT ?2", [Repo, ?RECENT_UPDATES]),
          {ok, U} <- [update_summary(Key)]].

update_summary(Key) ->
    case fetch(Key) of
        #message{author = A, timestamp = Ts, content = {P}} ->
            Commits = [#{sha1 => Sha, title => absent(proplists:get_value(~"title", C))}
                       || {C} <- list(proplists:get_value(~"commits", P)),
                          Sha <- [proplists:get_value(~"sha1", C)], is_binary(Sha)],
            Refs = case proplists:get_value(~"refs", P) of
                       {Rs} -> [#{name => N, hash => absent(H)} || {N, H} <- Rs];
                       _    -> []
                   end,
            More = case proplists:get_value(~"commits_more", P) of
                       N when is_integer(N) -> N;
                       _                    -> 0
                   end,
            {ok, #{key => Key, author => A, author_name => name(A), ts => Ts,
                   refs => Refs, commits => Commits, commits_more => More}};
        _ ->
            error
    end.

%% A repo's issues and/or pull requests, newest first.
%% Kind: issue | pull_request | all; State: open | closed | all.
issues(Repo, Kind, State) when is_binary(Repo) ->
    [summary(I) || I <- ssb_git_issues:issues(Repo, Kind, State)].

%% One issue or pull request: its text, and every change published to it.
issue(Id) when is_binary(Id) ->
    case ssb_git_issues:issue(Id) of
        {ok, #{edits := Edits} = I} ->
            Text = case fetch(Id) of
                       #message{content = {P}} ->
                           absent(body(maps:get(title, I), proplists:get_value(~"text", P, null)));
                       _ ->
                           nil
                   end,
            {ok, (summary(I))#{text => Text, comments => comments(Id),
                               edits => [#{msg => M, author => A, author_name => name(A),
                                           ts => Ts, open => absent(O),
                                           title => absent(T),
                                           counted => C}
                                         || #{msg := M, author := A, ts := Ts, open := O,
                                              title := T, counted := C} <- Edits]}};
        Err ->
            Err
    end.

%% The thread under an issue, in thread order, the issue itself left out:
%% [#{key, author, author_name, ts, text, depth}], depth 1 for a direct
%% reply.  ssb_conv's tangle builds the tree, as for maxbutt's threads.
comments(Root) ->
    Tree = try tangle:get_tangle(Root) catch _:_ -> {Root, nil, []} end,
    [C || {Key, _, Depth} <- tl(flatten(Tree, 0)),
          {ok, C} <- [comment_entry(Key, Depth)]].

flatten({Key, Author, Children}, D) when is_list(Children) ->
    [{Key, Author, D} | lists:flatmap(fun(C) -> flatten(C, D + 1) end, Children)];
flatten({Key, Author}, D) ->
    [{Key, Author, D}].

comment_entry(Key, Depth) ->
    case fetch(Key) of
        #message{author = A, timestamp = Ts, content = {P}} ->
            {ok, #{key => Key, author => A, author_name => name(A), ts => Ts,
                   depth => Depth,
                   text => absent(proplists:get_value(~"text", P, null))}};
        #message{author = A, timestamp = Ts} ->
            {ok, #{key => Key, author => A, author_name => name(A), ts => Ts,
                   depth => Depth, text => ~"(private message)"}};
        _ ->
            error
    end.

summary(#{author := A} = I) ->
    Fields = maps:with([id, kind, repo, author, ts, title, open, merged,
                        branch, head_repo, head_branch], I),
    (maps:map(fun(_, V) -> absent(V) end, Fields))
        #{author_name => name(A)}.

%%%===================================================================
%%% Writes
%%%===================================================================

%% {ok, Id} | {error, Reason}.
%%
%% The title goes in `title` and again as the first line of `text`.  Most
%% of the network's issues have no `title` and simply begin with it, and
%% clients that render an issue show only its text (silkpurse among them),
%% so a title kept only in `title` is a title most readers never see.
new_issue(Repo, Title, Text) when is_binary(Repo), is_binary(Title), is_binary(Text) ->
    publish({[{~"type", ~"issue"}, {~"project", Repo}, {~"title", Title},
              {~"text", titled(Title, Text)}]}).

%% A request to merge HeadRepo's HeadBranch into Repo's Branch.  `project`
%% repeats `repo`, as git-ssb wrote it, for readers that file by project.
new_pull_request(Repo, Branch, HeadRepo, HeadBranch, Title, Text)
  when is_binary(Repo), is_binary(Branch), is_binary(HeadRepo),
       is_binary(HeadBranch), is_binary(Title), is_binary(Text) ->
    publish({[{~"type", ~"pull-request"}, {~"repo", Repo}, {~"project", Repo},
              {~"branch", Branch}, {~"head_repo", HeadRepo},
              {~"head_branch", HeadBranch}, {~"title", Title},
              {~"text", titled(Title, Text)}]}).

%% The text as published: the title, then the body after a blank line.
titled(Title, <<>>) -> Title;
titled(Title, Text) -> <<Title/binary, "\n\n", Text/binary>>.

%% The body to show under a title: the text without a first line that
%% only repeats the title, as titled/2 writes it.
body(Title, Text) when is_binary(Title), is_binary(Text) ->
    case string:split(Text, "\n") of
        [First | Rest] ->
            case string:trim(string:trim(First), leading, "# ") =:= string:trim(Title) of
                true  -> string:trim(iolist_to_binary(Rest), leading, "\n");
                false -> Text
            end
    end;
body(_, Text) ->
    Text.

%% Close (false) or reopen (true), in the form most of the network's
%% issue-edits take.  Whether it changes what readers see depends on who
%% you are (ssb_git_issues): the issue's author or the repo's owner.
set_open(Id, Open) when is_binary(Id), is_boolean(Open) ->
    publish({[{~"type", ~"issue-edit"}, {~"root", Id},
              {~"issues", [{[{~"link", Id}, {~"open", Open}]}]}]}).

%% A comment: a post in the issue's thread.  `issue` and `repo` are what
%% git-ssb-web added, so its readers file the comment with the issue;
%% branch is the root alone, as maxbutt's own replies do.
comment(Id, Text) when is_binary(Id), is_binary(Text) ->
    Repo = case ssb_git_issues:issue(Id) of
               {ok, #{repo := R}} -> [{~"repo", R}];
               _                  -> []
           end,
    publish({[{~"type", ~"post"}, {~"root", Id}, {~"branch", [Id]},
              {~"text", Text}, {~"issue", Id}] ++ Repo}).

%%%===================================================================
%%% Internal
%%%===================================================================

publish(Content) ->
    Pid = utils:find_or_create_feed_pid(keys:pub_key_disp()),
    case ssb_feed:post_content(Pid, Content) of
        ok ->
            #message{id = Id} = ssb_feed:fetch_last_msg(Pid),
            {ok, Id};
        Err ->
            {error, Err}
    end.

fetch(Key) ->
    case mess_auth:get(Key) of
        not_found -> not_found;
        Author    -> ssb_feed:fetch_msg(utils:find_or_create_feed_pid(Author), Key)
    end.

name(Feed) ->
    case catch ssb_feed_meta:name(Feed) of
        B when is_binary(B), B =/= <<>> -> B;
        _                               -> nil
    end.

%% Absent, whichever way it arrived: null from JSON, undefined from a
%% NULL column (ssb_store) or an unset field.
absent(null)      -> nil;
absent(undefined) -> nil;
absent(V)         -> V.

list(L) when is_list(L) -> L;
list(_)                 -> [].

q(Sql, Params) ->
    try ssb_store:q(Sql, Params) of
        L when is_list(L) -> L;
        _                 -> []
    catch _:_ -> []
    end.

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

summary_test() ->
    I = #{id => ~"%i", kind => issue, repo => ~"%r", author => ~"@a", ts => 1,
          title => null, open => true, merged => false, branch => null,
          head_repo => null, head_branch => null, edits => [x]},
    S = summary(I),
    ?assertEqual(nil, maps:get(title, S)),
    ?assertNot(maps:is_key(edits, S)),
    ?assert(maps:is_key(author_name, S)).

titled_test_() ->
    [?_assertEqual(~"T\n\nbody", titled(~"T", ~"body")),
     ?_assertEqual(~"T", titled(~"T", <<>>))].

body_test_() ->
    [%% what titled/2 wrote: the title comes off
     ?_assertEqual(~"body\nmore", body(~"T", ~"T\n\nbody\nmore")),
     ?_assertEqual(<<>>, iolist_to_binary(body(~"T", ~"T"))),
     %% a markdown heading of the same title too
     ?_assertEqual(~"body", body(~"T", ~"# T\n\nbody")),
     %% an issue that does not start with its title keeps its text
     ?_assertEqual(~"Something else\nbody", body(~"T", ~"Something else\nbody")),
     %% no title (it came from the text), no text: unchanged
     ?_assertEqual(~"x", body(null, ~"x")),
     ?_assertEqual(null, body(~"T", null))].

flatten_test() ->
    Tree = {~"%r", ~"@a", [{~"%c1", ~"@b", [{~"%c2", ~"@a"}]}, {~"%c3", ~"@c", []}]},
    ?assertEqual([{~"%r", ~"@a", 0}, {~"%c1", ~"@b", 1}, {~"%c2", ~"@a", 2},
                  {~"%c3", ~"@c", 1}], flatten(Tree, 0)).

absent_test_() ->
    [?_assertEqual(nil, absent(null)), ?_assertEqual(nil, absent(undefined)),
     ?_assertEqual(~"x", absent(~"x")), ?_assertEqual(false, absent(false))].

activity_test() ->
    ?assertEqual(5, activity(#{pushed => nil, created => 5})),
    ?assertEqual(9, activity(#{pushed => 9, created => 5})).

-endif.
