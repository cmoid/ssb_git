%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% Push: turn git's `push <src>:<dst>` batch into one git-update message,
%% the way git-ssb's uploadPack (ssb-git-repo 2.8.3) built them.
%%
%%   1. resolve each src here; an empty src deletes dst (refs: null)
%%   2. pack what the repo lacks: rev-list --objects <new> --not <every
%%      hash the repo's updates have published that this clone holds>, into
%%      `git pack-objects --stdout` — NOT thin, so a reader never needs a
%%      base it does not have — and `git index-pack` it for the .idx that
%%      git-ssb readers use
%%   3. blobs.add the pack and idx (skipped when the node has them), then
%%      blobs.push both.  One over the blob cap goes up in 4 MB pieces,
%%      published as {link: <first>, size: <its size>, chunks: [<rest>]}:
%%      split bytes, not objects, so each piece is useless alone but the
%%      concatenation is the pack git made.  A git-ssb reader takes the
%%      first piece for a short pack and fails at index-pack, loudly.
%%   4. link the update into the repo's graph and publish it
%%
%% THE LINKS are built here, from git.updates (the repo's objects, their
%% links and published refs), not by the node.  refsBranch + repoBranch
%% together name every current head — an object nothing in the repo links
%% to — so the new update sits on top of everything this node has seen,
%% and the fold reads it as superseding all of it.  repoBranch is the
%% subset this push's objects depend on: git-ssb found those through
%% every object's parents, trees and blobs; here they are the updates that
%% published, as a ref value, a commit the push builds on (a parent of a
%% pushed commit, a pushed tag's target, or a ref moved to a commit the
%% repo already has), reduced to the ones no other such update links to.
%% It decides nothing the fold does — the fold counts every link alike —
%% but old git-ssb clients read it, and the fold's tie-break prefers an
%% update that set it.
%%
%% CONFLICT BRANCHES.  A push of master supersedes every concurrent value
%% of master, and with it the refs/heads/%<key>/master branches the fold
%% made of them.  As git-ssb did, any such branch the push does not
%% mention is written into the update with its current value, so no
%% commit is lost; one the push deletes is simply left out.
%%
%% CLOSING.  As in git-ssb, a commit newly reachable from the repo's HEAD
%% branch that says "fixes %<id>" (or close/closes/closed/closing,
%% fix/fixed/fixing, optionally "issue" before the id) closes that issue,
%% and one that is the tip of an open pull request against the repo closes
%% it as merged: `issues: [{link, open: false, merged?, object, label}]`.
%% Whether readers take the close is theirs to decide (ssb_git_issues
%% counts it from the issue's author or the repo's owner).
%%
%% SIZE.  An SSB message is at most 8192 characters.  On the node's "must
%% not be larger", object_ids goes first, then the commits (or tags) list
%% is halved until it fits, commits_more/tags_more counting what was cut.
%% git-ssb did it the other way round, moving each cut commit's id into
%% object_ids — which then filled the room the cut had made, so a big push
%% ended up carrying neither list.  Readers lose nothing either way: the
%% pack is the record of what was pushed, and the lists are a summary.
-module(ssb_git_push).

-export([push/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% The node's blob cap (ssb.hrl BLOB_MAX_SIZE, also ssb-blobs' default):
%% anything bigger is split into ?CHUNK pieces.  Chunks are smaller than
%% the cap so a piece is never the one a peer with a slightly lower limit
%% refuses.
-define(BLOB_MAX, 5242880).
-define(CHUNK, 4194304).

%% push(Peer, Repo, [{Src, Dst}]) -> ok | {error, Text}.  One update for
%% the whole batch, so the refs land or fail together.
push(Peer, Repo, Specs) ->
    try
        Refs0 = [{Dst, resolve(Src)} || {Src, Dst} <- Specs],
        Current = rpc(Peer, [~"git", ~"refs"], Repo),
        Updates = [update(U) || U <- rpc(Peer, [~"git", ~"updates"], Repo)],
        Refs = keep_conflicts(Refs0, [{N, H} || #{~"name" := N, ~"hash" := H}
                                                    <- maps:get(~"refs", Current)]),
        Have = ssb_git_local:present(published(Updates)),
        New = lists:usort([H || {_, H} <- Refs, H =/= null]),
        Objects = objects(New, Have),
        Pack = pack(Objects),
        Types = types(Objects),
        Commits = commits([Id || {Id, commit} <- Types]),
        Tags = [tag(Id) || {Id, tag} <- Types],
        Blobs = upload(Peer, Pack),
        Deps = deps(Commits, Tags, Refs, Types),
        {RefsBranch, RepoBranch} = links(Updates, Deps),
        Issues = closes(Peer, Repo, Current, Refs),
        Content = #{repo => Repo, refs => Refs, issues => Issues,
                    refs_branch => RefsBranch, repo_branch => RepoBranch,
                    blobs => Blobs, num_objects => length(Objects),
                    commits => Commits, tags => Tags,
                    object_ids => [Id || {Id, T} <- Types,
                                         T =/= commit, T =/= tag]},
        Key = publish(Peer, Content),
        [ssb_git_local:record_absorbed(P) || {pack, [{P, _} | _]} <- Blobs],
        io:format(standard_error, "git-remote-ssb: published ~s~n", [Key]),
        ok
    catch
        throw:{push_failed, Text} -> {error, Text}
    end.

fail(Fmt, Args) ->
    throw({push_failed, lists:flatten(io_lib:format(Fmt, Args))}).

rpc(Peer, Method, Repo) ->
    case ssb_git_client:call(Peer, Method, [{[{~"repo", Repo}]}]) of
        {ok, V}         -> V;
        {error, Reason} -> fail("~s: ~p", [lists:join(".", Method), Reason])
    end.

update(#{~"key" := K, ~"links" := L, ~"refs" := R}) ->
    #{key => K, links => L, refs => [{N, H} || [N, H] <- R]}.

%%%===================================================================
%%% What to send
%%%===================================================================

resolve(<<>>) ->
    null;
resolve(Src) ->
    case ssb_git_local:git(["rev-parse", "--verify", "--quiet", Src]) of
        {0, Out} -> string:trim(Out);
        _        -> fail("~s does not name an object here", [Src])
    end.

%% Every hash the repo's updates have published as a ref value: what
%% readers of the repo already have objects for.
published(Updates) ->
    lists:usort([H || #{refs := Rs} <- Updates, {_, H} <- Rs, is_binary(H)]).

%% [{Id, Line}] for every object reachable from New and not from Have,
%% Line being rev-list's "<id> <path>" (pack-objects uses the path to
%% choose delta bases).
objects([], _Have) ->
    [];
objects(New, Have) ->
    In = [[[N, $\n] || N <- New], [[$^, H, $\n] || H <- Have]],
    case ssb_git_local:git_in(["rev-list", "--objects", "--stdin"], In) of
        {0, Out} ->
            [{binary:part(L, 0, 40), L}
             || L <- binary:split(Out, <<"\n">>, [global, trim_all])];
        {S, _} ->
            fail("git rev-list exited ~p", [S])
    end.

pack([]) ->
    none;
pack(Objects) ->
    In = [[L, $\n] || {_, L} <- Objects],
    case ssb_git_local:git_in(["pack-objects", "--stdout", "-q"], In) of
        {0, Pack} ->
            {Pack, index(Pack)};
        {S, _} ->
            fail("git pack-objects exited ~p", [S])
    end.

%% The .idx for Pack.  index-pack needs the pack in a file, and leaves the
%% idx (and, on newer git, a .rev) beside it.
index(Pack) ->
    Base = filename:join(ssb_git_local:state_dir(),
                         "push." ++ integer_to_list(erlang:unique_integer([positive]))),
    PackFile = Base ++ ".pack",
    IdxFile = Base ++ ".idx",
    ok = file:write_file(PackFile, Pack),
    try ssb_git_local:git(["index-pack", "-o", IdxFile, PackFile]) of
        {0, _} -> {ok, Idx} = file:read_file(IdxFile), Idx;
        {S, _} -> fail("git index-pack exited ~p", [S])
    after
        [file:delete(Base ++ Ext) || Ext <- [".pack", ".idx", ".rev"]]
    end.

%% [{Id, commit | tree | blob | tag}] in rev-list order.
types([]) ->
    [];
types(Objects) ->
    In = [[Id, $\n] || {Id, _} <- Objects],
    case ssb_git_local:git_in(["cat-file", "--batch-check=%(objectname) %(objecttype)"], In) of
        {0, Out} ->
            [{Id, binary_to_atom(T)}
             || L <- binary:split(Out, <<"\n">>, [global, trim_all]),
                [Id, T] <- [binary:split(L, <<" ">>)]];
        {S, _} ->
            fail("git cat-file exited ~p", [S])
    end.

%% #{sha1, parents, title, body?} for each commit, newest commit date
%% first as git-ssb sorted them.
commits([]) ->
    [];
commits(Ids) ->
    In = [[Id, $\n] || Id <- Ids],
    case ssb_git_local:git_in(["log", "--no-walk=unsorted", "--stdin", "-z",
                               "--format=%H%n%P%n%ct%n%B"], In) of
        {0, Out} ->
            Parsed = [parse_commit(R) || R <- binary:split(Out, <<0>>, [global, trim_all])],
            [maps:remove(date, C)
             || C <- lists:sort(fun(A, B) -> maps:get(date, A) >= maps:get(date, B) end,
                                Parsed)];
        {S, _} ->
            fail("git log exited ~p", [S])
    end.

parse_commit(Record) ->
    [Sha, R1] = binary:split(Record, <<"\n">>),
    [Parents, R2] = binary:split(R1, <<"\n">>),
    [Date, Message] = case binary:split(R2, <<"\n">>) of
                          [D, M] -> [D, M];
                          [D]    -> [D, <<>>]
                      end,
    {Title, Body} = title_body(Message),
    #{sha1 => Sha,
      parents => binary:split(Parents, <<" ">>, [global, trim_all]),
      date => binary_to_integer(Date),
      title => Title,
      body => Body}.

%% First line, and what follows it after the blank line (absent if none).
title_body(Message) ->
    case binary:split(string:trim(Message, trailing), <<"\n">>) of
        [Title]       -> {Title, undefined};
        [Title, Rest] -> case string:trim(Rest, leading, "\n") of
                             <<>> -> {Title, undefined};
                             Body -> {Title, Body}
                         end
    end.

%% #{sha1, object, type, tag, title} for an annotated tag.
tag(Id) ->
    case ssb_git_local:git(["cat-file", "tag", Id]) of
        {0, Out} -> parse_tag(Id, Out);
        {S, _}   -> fail("git cat-file tag ~s exited ~p", [Id, S])
    end.

parse_tag(Id, Raw) ->
    {Head, Message} = case binary:split(Raw, <<"\n\n">>) of
                          [H, M] -> {H, M};
                          [H]    -> {H, <<>>}
                      end,
    Fields = [list_to_tuple(binary:split(L, <<" ">>))
              || L <- binary:split(Head, <<"\n">>, [global, trim_all])],
    {Title, _} = title_body(Message),
    #{sha1 => Id,
      object => proplists:get_value(~"object", Fields),
      type => proplists:get_value(~"type", Fields),
      tag => proplists:get_value(~"tag", Fields),
      title => Title}.

%%%===================================================================
%%% Blobs
%%%===================================================================

%% [{pack, Pieces}, {idx, Pieces}], each Pieces [{Id, Size}] in order —
%% one piece unless the blob was over the cap — stored and announced.
upload(_Peer, none) ->
    [];
upload(Peer, {Pack, Idx}) ->
    [{Kind, [store(Peer, Kind, P) || P <- pieces(Bytes)]}
     || {Kind, Bytes} <- [{pack, Pack}, {idx, Idx}]].

store(Peer, Kind, Bytes) ->
    Id = ssb_git_local:blob_id(Bytes),
    case ssb_git_client:call(Peer, [~"blobs", ~"has"], [Id]) of
        {ok, true} -> ok;
        _ ->
            case ssb_git_client:add_blob(Peer, Bytes) of
                ok              -> ok;
                {error, Reason} -> fail("blobs.add ~s: ~p", [Kind, Reason])
            end
    end,
    ssb_git_client:call(Peer, [~"blobs", ~"push"], [Id]),
    {Id, byte_size(Bytes)}.

pieces(Bytes) when byte_size(Bytes) =< ?BLOB_MAX ->
    [Bytes];
pieces(Bytes) ->
    split(Bytes).

split(<<P:?CHUNK/binary, Rest/binary>>) when Rest =/= <<>> -> [P | split(Rest)];
split(Last)                                                -> [Last].

%%%===================================================================
%%% Links
%%%===================================================================

%% Conflict branches the push would make disappear, kept explicitly.
%% Refs is the push, in git's order; Current the repo's refs now.  A
%% conflict branch the push deletes, alongside its real name, is left out
%% rather than published as null: superseding it is deletion enough.
keep_conflicts(Refs, Current) ->
    Pushed = [N || {N, _} <- Refs],
    Resolved = fun(Name) ->
                       case ssb_git_fold:realname(Name) of
                           {ok, Real} -> lists:member(Real, Pushed);
                           error      -> false
                       end
               end,
    Kept = [{Name, Hash} || {Name, Hash} <- Current,
                            Resolved(Name), not lists:member(Name, Pushed)],
    [R || {N, H} = R <- Refs, not (H =:= null andalso Resolved(N))] ++ Kept.

%% Commits the push builds on without sending: parents outside it, tag
%% targets outside it, and refs moved to an object it does not include.
deps(Commits, Tags, Refs, Types) ->
    Sent = maps:from_list([{Id, true} || {Id, _} <- Types]),
    Out = fun(Id) -> not maps:is_key(Id, Sent) end,
    lists:usort([P || #{parents := Ps} <- Commits, P <- Ps, Out(P)]
                ++ [O || #{object := O} <- Tags, is_binary(O), Out(O)]
                ++ [H || {_, H} <- Refs, is_binary(H), Out(H)]).

%% {RefsBranch, RepoBranch} for an update on top of Updates.
links(Updates, Deps) ->
    Keys = [K || #{key := K} <- Updates],
    InGraph = sets:from_list(Keys, [{version, 2}]),
    Edges = maps:from_list(
              [{K, [L || L <- Ls, L =/= K, sets:is_element(L, InGraph)]}
               || #{key := K, links := Ls} <- Updates]),
    Heads = heads(Keys, Edges),
    DepSet = sets:from_list(Deps, [{version, 2}]),
    Holders = [K || #{key := K, refs := Rs} <- Updates,
                    lists:any(fun({_, H}) -> sets:is_element(H, DepSet) end, Rs)],
    RepoBranch = heads(Holders, Edges),
    {[H || H <- Heads, not lists:member(H, RepoBranch)], RepoBranch}.

%% The members of Keys that no other member reaches, in Keys' order.
heads(Keys, Edges) ->
    Reached = lists:foldl(fun(K, Acc) -> reach(maps:get(K, Edges, []), Edges, Acc) end,
                          sets:new([{version, 2}]), Keys),
    [K || K <- Keys, not sets:is_element(K, Reached)].

reach([], _Edges, Seen) ->
    Seen;
reach([K | Rest], Edges, Seen) ->
    case sets:is_element(K, Seen) of
        true  -> reach(Rest, Edges, Seen);
        false -> reach(maps:get(K, Edges, []) ++ Rest, Edges, sets:add_element(K, Seen))
    end.

%%%===================================================================
%%% Closing issues
%%%===================================================================

-define(CLOSES, "(?:[Cc]los(?:e[sd]?|ing)|[Ff]ix(?:e[sd]|ing)?) +(?:issue +)?"
                "(%[A-Za-z0-9/+]{43}=\\.sha256)").

%% The issues entries for this push: [] unless it moves HEAD's branch.
closes(Peer, Repo, Current, Refs) ->
    Head = maps:get(~"head", Current, null),
    case lists:keyfind(Head, 1, Refs) of
        {Head, New} when is_binary(New) ->
            Old = [H || #{~"name" := N, ~"hash" := H} <- maps:get(~"refs", Current),
                        N =:= Head],
            Merged = commits(merged(New, ssb_git_local:present(Old))),
            dedup_links(mentions(Merged) ++ merged_prs(Peer, Repo, Merged));
        _ ->
            []
    end.

%% Commits now reachable from New that were not from the old HEAD.
merged(New, Old) ->
    In = [[New, $\n], [[$^, O, $\n] || O <- Old]],
    case ssb_git_local:git_in(["rev-list", "--stdin"], In) of
        {0, Out} -> binary:split(Out, <<"\n">>, [global, trim_all]);
        {S, _}   -> fail("git rev-list exited ~p", [S])
    end.

%% "fixes %<id>" in a commit's title or body.
mentions(Commits) ->
    [#{link => Id, object => Sha, label => Title}
     || #{sha1 := Sha, title := Title} = C <- Commits,
        Id <- closed_ids(text_of(C))].

closed_ids(Text) ->
    case re:run(Text, ?CLOSES, [global, {capture, all_but_first, binary}, unicode]) of
        {match, Ms} -> [Id || [Id] <- Ms];
        nomatch     -> []
    end.

text_of(#{title := T, body := B}) ->
    iolist_to_binary([T, "\n\n", case B of undefined -> <<>>; _ -> B end]).

%% Open pull requests against Repo whose head branch now points at a
%% commit this push merges.
merged_prs(_Peer, _Repo, []) ->
    [];
merged_prs(Peer, Repo, Merged) ->
    Shas = maps:from_list([{Sha, T} || #{sha1 := Sha, title := T} <- Merged]),
    Open = case ssb_git_client:call(Peer, [~"git", ~"issues"],
                                    [{[{~"repo", Repo}, {~"kind", ~"pull-request"}]}]) of
               {ok, L} when is_list(L) -> L;
               _                       -> []
           end,
    [#{link => Pr, object => Tip, label => maps:get(Tip, Shas), merged => true}
     || #{~"id" := Pr, ~"head_repo" := HeadRepo, ~"head_branch" := HeadBranch} <- Open,
        Tip <- [branch_tip(Peer, HeadRepo, HeadBranch)],
        is_map_key(Tip, Shas)].

branch_tip(Peer, Repo, Branch) ->
    Name = case Branch of
               <<"refs/", _/binary>> -> Branch;
               _                     -> <<"refs/heads/", Branch/binary>>
           end,
    case ssb_git_client:call(Peer, [~"git", ~"refs"], [{[{~"repo", Repo}]}]) of
        {ok, #{~"refs" := Refs}} ->
            case [H || #{~"name" := N, ~"hash" := H} <- Refs, N =:= Name] of
                [H | _] -> H;
                []      -> none
            end;
        _ ->
            none
    end.

%% One entry per issue, the first (a merge before a mention) winning.
dedup_links(Entries) ->
    Merges = [E || #{merged := true} = E <- Entries],
    Rest = [E || E <- Entries, not maps:is_key(merged, E)],
    lists:reverse(
      lists:foldl(fun(#{link := L} = E, Acc) ->
                          case lists:any(fun(#{link := L2}) -> L2 =:= L end, Acc) of
                              true  -> Acc;
                              false -> [E | Acc]
                          end
                  end, [], Merges ++ Rest)).

issue_json(#{link := L, object := O, label := T} = E) ->
    {[{~"link", L}, {~"open", false}]
     ++ [{~"merged", true} || maps:get(merged, E, false)]
     ++ [{~"object", O}, {~"label", T}]}.

%%%===================================================================
%%% The message
%%%===================================================================

%% Publish, shrinking on "too large" as git-ssb did.  The message key.
publish(Peer, C) ->
    case ssb_git_client:call(Peer, [~"publish"], [content(C)]) of
        {ok, #{~"key" := Key}} ->
            Key;
        {error, Msg} when is_binary(Msg) ->
            case binary:match(Msg, ~"must not be larger") of
                nomatch -> fail("publish: ~s", [Msg]);
                _ ->
                    case shrink(C) of
                        {ok, C1} -> publish(Peer, C1);
                        error    -> fail("publish: the update is too large "
                                         "even with no commit list: ~s", [Msg])
                    end
            end;
        Other ->
            fail("publish: ~p", [Other])
    end.

%% One step smaller: drop object_ids; after that, halve the longer of
%% commits and tags, counting what was cut in commits_more/tags_more.
shrink(#{object_ids := _} = C) ->
    {ok, maps:remove(object_ids, C)};
shrink(#{commits := Cs, tags := Ts} = C) when length(Cs) > 0, length(Cs) >= length(Ts) ->
    {Keep, Drop} = lists:split(length(Cs) div 2, Cs),
    {ok, C#{commits => Keep,
            commits_more => maps:get(commits_more, C, 0) + length(Drop)}};
shrink(#{tags := Ts} = C) when Ts =/= [] ->
    {Keep, Drop} = lists:split(length(Ts) div 2, Ts),
    {ok, C#{tags => Keep,
            tags_more => maps:get(tags_more, C, 0) + length(Drop)}};
shrink(_) ->
    error.

%% The git-update content, fields in the order current git-ssb wrote them.
content(C) ->
    #{repo := Repo, refs := Refs, refs_branch := RefsB, repo_branch := RepoB,
      blobs := Blobs, commits := Cs, tags := Ts} = C,
    Packs = [link_json(Ps) || {pack, Ps} <- Blobs],
    Idxs = [link_json(Ps) || {idx, Ps} <- Blobs],
    {[{~"type", ~"git-update"},
      {~"repo", Repo},
      {~"refsBranch", RefsB}]
     ++ [{~"repoBranch", RepoB} || RepoB =/= []]
     ++ [{~"packs", Packs} || Packs =/= []]
     ++ [{~"indexes", Idxs} || Idxs =/= []]
     ++ [{~"refs", {Refs}}]
     ++ [{~"issues", [issue_json(I) || I <- Is]} || Is <- [maps:get(issues, C, [])], Is =/= []]
     ++ [{~"num_objects", maps:get(num_objects, C)} || Packs =/= []]
     ++ [{~"commits", [commit_json(X) || X <- Cs]}]
     ++ [{~"commits_more", N} || N <- [maps:get(commits_more, C, 0)], N > 0]
     ++ [{~"tags", [tag_json(X) || X <- Ts]}]
     ++ [{~"tags_more", N} || N <- [maps:get(tags_more, C, 0)], N > 0]
     ++ [{~"object_ids", Ids} || Ids <- [maps:get(object_ids, C, undefined)],
                                 Ids =/= undefined]}.

%% {link, size} describe the first piece, as a link's size always
%% describes the blob it links; chunks lists the rest.
link_json([{Id, Size} | Rest]) ->
    {[{~"link", Id}, {~"size", Size}]
     ++ [{~"chunks", [I || {I, _} <- Rest]} || Rest =/= []]}.

commit_json(#{sha1 := Sha, parents := Ps, title := T, body := B}) ->
    {[{~"parents", Ps}, {~"title", T}]
     ++ [{~"body", B} || B =/= undefined]
     ++ [{~"sha1", Sha}]}.

tag_json(#{sha1 := Sha, object := O, type := Ty, tag := Tag, title := T}) ->
    {[{~"object", O}, {~"type", Ty}, {~"tag", Tag}, {~"title", T}, {~"sha1", Sha}]}.

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

-define(R, ~"%repo.sha256").

upd(K, Links, Refs) -> #{key => K, links => Links, refs => Refs}.

%% repo <- u1 <- u2 (master), and u3 (dev) also on u1: heads u2, u3.
graph() ->
    [upd(?R, [], []),
     upd(~"%u2", [?R, ~"%u1"], [{~"refs/heads/master", ~"c2"}]),
     upd(~"%u3", [?R, ~"%u1"], [{~"refs/heads/dev", ~"d1"}]),
     upd(~"%u1", [?R, ~"%ext"], [{~"refs/heads/master", ~"c1"}])].

links_test_() ->
    [%% first push: the repo message is the only head
     ?_assertEqual({[?R], []}, links([upd(?R, [], [])], [])),
     %% building on master's tip: u2 is the dependency, u3 the other head
     ?_assertEqual({[~"%u3"], [~"%u2"]}, links(graph(), [~"c2"])),
     %% building on c1 and c2: u1 is below u2, so only u2 is a head of them
     ?_assertEqual({[~"%u3"], [~"%u2"]}, links(graph(), [~"c1", ~"c2"])),
     %% a commit no update named: every head goes in refsBranch
     ?_assertEqual({[~"%u2", ~"%u3"], []}, links(graph(), [~"zz"])),
     %% links outside the graph (~"%ext") are not heads or edges
     ?_assertEqual([~"%u2", ~"%u3"],
                   heads([K || #{key := K} <- graph()],
                         maps:from_list([{K, [L || L <- Ls, L =/= ~"%ext"]}
                                         || #{key := K, links := Ls} <- graph()])))].

keep_conflicts_test_() ->
    K = ~"%AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=.sha256",
    Conf = <<"refs/heads/", K/binary, "/master">>,
    Current = [{~"refs/heads/master", ~"m"}, {Conf, ~"x"}, {~"refs/heads/dev", ~"d"}],
    [%% pushing master keeps the other side of its conflict
     ?_assertEqual([{~"refs/heads/master", ~"n"}, {Conf, ~"x"}],
                   keep_conflicts([{~"refs/heads/master", ~"n"}], Current)),
     %% deleting the conflict branch alongside lets it go
     ?_assertEqual([{~"refs/heads/master", ~"n"}],
                   keep_conflicts([{~"refs/heads/master", ~"n"}, {Conf, null}], Current)),
     %% pushing dev touches no conflict
     ?_assertEqual([{~"refs/heads/dev", ~"e"}],
                   keep_conflicts([{~"refs/heads/dev", ~"e"}], Current))].

deps_test() ->
    Commits = [#{sha1 => ~"b", parents => [~"a"]}, #{sha1 => ~"a", parents => [~"p"]}],
    Tags = [#{sha1 => ~"t", object => ~"old"}],
    Types = [{~"b", commit}, {~"a", commit}, {~"t", tag}],
    Refs = [{~"refs/heads/x", ~"b"}, {~"refs/heads/y", ~"elsewhere"}, {~"refs/heads/z", null}],
    ?assertEqual([~"elsewhere", ~"old", ~"p"], deps(Commits, Tags, Refs, Types)).

title_body_test_() ->
    [?_assertEqual({~"One", undefined}, title_body(~"One\n")),
     ?_assertEqual({~"One", ~"Two\nthree"}, title_body(~"One\n\nTwo\nthree\n")),
     ?_assertEqual({~"One", undefined}, title_body(~"One\n\n\n"))].

parse_commit_test() ->
    ?assertEqual(#{sha1 => ~"abc", parents => [~"p1", ~"p2"], date => 17,
                   title => ~"Fix it", body => ~"Because."},
                 parse_commit(~"abc\np1 p2\n17\nFix it\n\nBecause.\n")),
    ?assertMatch(#{parents := []}, parse_commit(~"abc\n\n17\nRoot\n")).

parse_tag_test() ->
    Raw = ~"object a96f\ntype commit\ntag 0.4.0\ntagger A <a@b> 1 +0000\n\nv0.4.0\n",
    ?assertEqual(#{sha1 => ~"t", object => ~"a96f", type => ~"commit",
                   tag => ~"0.4.0", title => ~"v0.4.0"}, parse_tag(~"t", Raw)).

shrink_test() ->
    C0 = #{commits => [#{sha1 => integer_to_binary(N)} || N <- lists:seq(1, 4)],
           tags => [#{sha1 => ~"t"}], object_ids => [~"tree"]},
    %% object_ids first, commits untouched
    {ok, C1} = shrink(C0),
    ?assertNot(maps:is_key(object_ids, C1)),
    ?assertEqual(4, length(maps:get(commits, C1))),
    %% then commits halve, keeping the newest
    {ok, C2} = shrink(C1),
    ?assertEqual([~"1", ~"2"], [Id || #{sha1 := Id} <- maps:get(commits, C2)]),
    ?assertEqual(2, maps:get(commits_more, C2)),
    {ok, C3} = shrink(C2),
    ?assertEqual(1, length(maps:get(commits, C3))),
    %% commits and tags level: commits still go first
    {ok, C4} = shrink(C3),
    ?assertEqual({[], 4}, {maps:get(commits, C4), maps:get(commits_more, C4)}),
    {ok, C5} = shrink(C4),
    ?assertEqual({[], 1}, {maps:get(tags, C5), maps:get(tags_more, C5)}),
    ?assertEqual(error, shrink(C5)).

pieces_test_() ->
    Big = binary:copy(<<"x">>, ?BLOB_MAX + 1),
    [?_assertEqual([~"small"], pieces(~"small")),
     %% exactly the cap is still one blob
     ?_assertEqual(1, length(pieces(binary:copy(<<"x">>, ?BLOB_MAX)))),
     ?_assertEqual([?CHUNK, ?BLOB_MAX + 1 - ?CHUNK], [byte_size(P) || P <- pieces(Big)]),
     ?_assertEqual(Big, iolist_to_binary(pieces(Big))),
     %% a multiple of the chunk size leaves no empty last piece
     ?_assertEqual([?CHUNK, ?CHUNK],
                   [byte_size(P) || P <- pieces(binary:copy(<<"x">>, 2 * ?CHUNK))])].

link_json_test_() ->
    [?_assertEqual({[{~"link", ~"&a"}, {~"size", 3}]}, link_json([{~"&a", 3}])),
     ?_assertEqual({[{~"link", ~"&a"}, {~"size", 3}, {~"chunks", [~"&b", ~"&c"]}]},
                   link_json([{~"&a", 3}, {~"&b", 4}, {~"&c", 1}]))].

closed_ids_test_() ->
    Id = ~"%n92DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU=.sha256",
    Id2 = ~"%AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=.sha256",
    [?_assertEqual([Id], closed_ids(<<"Fixes ", Id/binary>>)),
     ?_assertEqual([Id], closed_ids(<<"this closes issue ", Id/binary, " at last">>)),
     ?_assertEqual([Id, Id2], closed_ids(<<"fixed ", Id/binary, ", closing ", Id2/binary>>)),
     %% a mention is not a close
     ?_assertEqual([], closed_ids(<<"see ", Id/binary>>)),
     ?_assertEqual([], closed_ids(~"Fixes nothing"))].

dedup_links_test() ->
    A = #{link => ~"%a", object => ~"1", label => ~"x"},
    M = #{link => ~"%a", object => ~"2", label => ~"y", merged => true},
    B = #{link => ~"%b", object => ~"1", label => ~"x"},
    ?assertEqual([M, B], dedup_links([A, B, M])).

issue_json_test() ->
    ?assertEqual({[{~"link", ~"%p"}, {~"open", false}, {~"merged", true},
                   {~"object", ~"s"}, {~"label", ~"t"}]},
                 issue_json(#{link => ~"%p", object => ~"s", label => ~"t", merged => true})).

content_order_test() ->
    C = #{repo => ?R, refs => [{~"refs/heads/master", ~"c"}],
          refs_branch => [?R], repo_branch => [],
          blobs => [{pack, [{~"&p", 10}]}, {idx, [{~"&i", 5}]}], num_objects => 3,
          commits => [], tags => [], object_ids => []},
    {Props} = content(C),
    ?assertEqual([~"type", ~"repo", ~"refsBranch", ~"packs", ~"indexes", ~"refs",
                  ~"num_objects", ~"commits", ~"tags", ~"object_ids"],
                 [K || {K, _} <- Props]).

-endif.
