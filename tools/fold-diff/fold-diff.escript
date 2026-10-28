#!/usr/bin/env escript
%% -*- mode: erlang -*-
%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% fold-diff: does ssb_git_fold agree with git-ssb on real repos?
%%
%%   git ssb dump /tmp/git.ndjson
%%   (cd tools/fold-diff && npm install)
%%   node tools/fold-diff/reference.js /tmp/git.ndjson > /tmp/ref.json
%%   tools/fold-diff/fold-diff.escript /tmp/git.ndjson /tmp/ref.json
%%
%% Folds every repo in the dump with ssb_git_fold — same grouping, same
%% object order as reference.js — and compares refs (exactly, and as a
%% set) and HEAD.  Exits non-zero on any difference, printing the first
%% few.  Needs `make` first: it loads the beams from _build/default.
%%
%%   tools/fold-diff/fold-diff.escript /tmp/git.ndjson --self
%%
%% folds everything without a reference and reports what it found: a
%% smoke test for the fold on real data, nothing more.

main([Dump, "--self"]) ->
    Here = filename:dirname(filename:absname(escript:script_name())),
    true = code:add_patha(filename:join(Here, "../../_build/default/lib/ssb_git/ebin")),
    {Repos, Updates} = read_dump(Dump),
    Memo = ets:new(memo, [set]),
    Folded = [ours(Id, Repos, Updates, Memo) || Id <- lists:sort(maps:keys(Repos))],
    Refs = lists:append([R || #{refs := R} <- Folded]),
    Conflicts = [N || {N, _} <- Refs, binary:match(N, <<"/%">>) =/= nomatch],
    io:format("repos: ~p (~p with no refs)~n"
              "refs: ~p, of which conflict branches: ~p~n"
              "orphan updates (repo message not in the dump): ~p~n",
              [length(Folded), length([F || #{refs := []} = F <- Folded]),
               length(Refs), length(Conflicts),
               lists:sum([length(L) || {R, L} <- maps:to_list(Updates),
                                       not is_map_key(R, Repos)])]),
    halt(0);
main([Dump, Reference]) ->
    Here = filename:dirname(filename:absname(escript:script_name())),
    true = code:add_patha(filename:join(Here, "../../_build/default/lib/ssb_git/ebin")),
    {Repos, Updates} = read_dump(Dump),
    {ok, RefBin} = file:read_file(Reference),
    Ref = json:decode(RefBin),
    Ids = lists:sort(maps:keys(Repos)),
    Memo = ets:new(memo, [set]),
    Results = [{Id, ours(Id, Repos, Updates, Memo), theirs(Id, Ref)} || Id <- Ids],
    Exact  = [Id || {Id, O, T} <- Results, O =:= T],
    SameSet = [Id || {Id, #{refs := Ro, head := Ho}, #{refs := Rt, head := Ht}} <- Results,
                     lists:sort(Ro) =:= lists:sort(Rt), Ho =:= Ht],
    Diffs  = [R || {Id, _, _} = R <- Results, not lists:member(Id, SameSet)],
    io:format("repos: ~p~n"
              "identical (refs in the same order, same HEAD): ~p~n"
              "same refs and HEAD, order aside:               ~p~n"
              "different:                                     ~p~n",
              [length(Ids), length(Exact), length(SameSet), length(Diffs)]),
    [show(D) || D <- lists:sublist(Diffs, 5)],
    halt(case Diffs of [] -> 0; _ -> 1 end);
main(_) ->
    io:format(standard_error,
              "usage: fold-diff.escript DUMP.ndjson REFERENCE.json~n", []),
    halt(2).

%% {RepoId => Msg}, {RepoId => [UpdateMsg]} from a `git ssb dump`, every
%% message as EJSON so object key order survives (merge.js depends on it).
read_dump(File) ->
    {ok, Bin} = file:read_file(File),
    lists:foldl(
      fun(<<>>, Acc) -> Acc;
         (Line, {Rs, Us}) ->
              Msg = {Props} = ejson(Line),
              {Value} = proplists:get_value(<<"value">>, Props),
              Key = proplists:get_value(<<"key">>, Props),
              case proplists:get_value(<<"content">>, Value) of
                  {C} ->
                      case {proplists:get_value(<<"type">>, C),
                            proplists:get_value(<<"repo">>, C)} of
                          {<<"git-repo">>, _} ->
                              {Rs#{Key => Msg}, Us};
                          {<<"git-update">>, Repo} when is_binary(Repo) ->
                              {Rs, maps:update_with(Repo, fun(L) -> [Msg | L] end,
                                                    [Msg], Us)};
                          _ ->
                              {Rs, Us}
                      end;
                  _ ->
                      {Rs, Us}          %% private: not indexed
              end
      end, {#{}, #{}}, binary:split(Bin, <<"\n">>, [global])).

ejson(Bin) ->
    {V, ok, _} = json:decode(Bin, ok,
                             #{object_finish => fun(Acc, Old) ->
                                                        {{lists:reverse(Acc)}, Old}
                                                end}),
    V.

%% Newest first, ties by key — reference.js's newestFirst.
newest_first(A, B) ->
    {Ta, Ka} = ts_key(A),
    {Tb, Kb} = ts_key(B),
    if Ta =/= Tb -> Ta > Tb;
       true      -> Ka =< Kb
    end.

ts_key({Props}) ->
    {Value} = proplists:get_value(<<"value">>, Props),
    Ts = case proplists:get_value(<<"timestamp">>, Value) of
             N when is_number(N) -> N;
             _                   -> 0
         end,
    {Ts, proplists:get_value(<<"key">>, Props)}.

own(Id, Repos, Updates, Memo) ->
    case ets:lookup(Memo, Id) of
        [{_, R}] -> R;
        [] ->
            Us = lists:sort(fun newest_first/2, maps:get(Id, Updates, [])),
            R = ssb_git_fold:fold([ssb_git_fold:object(M)
                                   || M <- [maps:get(Id, Repos) | Us]]),
            ets:insert(Memo, {Id, R}),
            R
    end.

ours(Id, Repos, Updates, Memo) ->
    #{head := Head} = own(Id, Repos, Updates, Memo),
    #{refs => unique(refs(Id, Repos, Updates, Memo, #{Id => true})),
      head => Head}.

refs(Id, Repos, Updates, Memo, Seen) ->
    #{refs := Own} = own(Id, Repos, Updates, Memo),
    {RProps} = maps:get(Id, Repos),
    {Value} = proplists:get_value(<<"value">>, RProps),
    {C} = proplists:get_value(<<"content">>, Value),
    case proplists:get_value(<<"upstream">>, C) of
        Up when is_binary(Up), is_map_key(Up, Repos), not is_map_key(Up, Seen) ->
            Own ++ refs(Up, Repos, Updates, Memo, Seen#{Up => true});
        _ ->
            Own
    end.

unique(Pairs) ->
    {L, _} = lists:foldl(fun({N, _} = P, {Acc, S}) ->
                                 case S of
                                     #{N := _} -> {Acc, S};
                                     _         -> {[P | Acc], S#{N => true}}
                                 end
                         end, {[], #{}}, Pairs),
    lists:reverse(L).

theirs(Id, Ref) ->
    #{<<"head">> := Head, <<"refs">> := Refs} = maps:get(Id, Ref),
    #{refs => [{N, H} || [N, H] <- Refs], head => Head}.

show({Id, #{refs := Ro, head := Ho}, #{refs := Rt, head := Ht}}) ->
    io:format("~n~s~n", [Id]),
    [io:format("  HEAD ours ~s, git-ssb ~s~n", [Ho, Ht]) || Ho =/= Ht],
    [io:format("  only ours:    ~s ~s~n", [N, H]) || {N, H} <- Ro -- Rt],
    [io:format("  only git-ssb: ~s ~s~n", [N, H]) || {N, H} <- Rt -- Ro],
    ok.
