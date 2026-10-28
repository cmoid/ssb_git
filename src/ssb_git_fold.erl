%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% The ref fold: a repo's branches, from its git-update messages.
%%
%% A port of git-ssb's — ssb-git 0.5.0 merge.js, driven by kvgraph's
%% reduceRight as ssb-git-repo does — and deliberately a faithful one,
%% quirks included, because there are 10,429 real updates on the network
%% whose meaning is whatever that code made of them.  tools/fold-diff runs
%% both over real data and compares.
%%
%% THE GRAPH.  The objects are the git-repo message and its updates.  An
%% object links to every other object whose id appears ANYWHERE among its
%% string values — kvgraph walks the whole message, so `repo`,
%% `repoBranch`, `refsBranch`, a mention, and even `previous` (when the
%% author's previous message was a push to the same repo) are all edges.
%% Roots are objects that link to nothing in the graph: normally just the
%% repo message, but an old client that set no repoBranch makes its update
%% a second root.
%%
%% THE FOLD.  state(X) = merge([state(Y) || Y links to X], X), memoised,
%% and the result is merge([state(R) || R <- roots], none).  So each state
%% summarises everything published AFTER (on top of) its message:
%%
%%   - for each ref, per author, the update with the highest sequence
%%     wins (a feed is totally ordered);
%%   - one author's value: that is the ref;
%%   - several authors' values: no winner.  Each becomes a conflict
%%     branch, refs/heads/%<msgkey>/<name>, and the plain name falls back
%%     to whatever the message below them said;
%%   - the message's own refs fill in names nothing above it set.
%%
%%   At the top, a conflict whose plain name ended up with no value at all
%%   has one of its branches promoted to the plain name: preferring an
%%   update that set repoBranch, then the latest claimed timestamp.  HEAD
%%   is then refs/heads/master if it exists, else the last ref.
%%
%% ORDER MATTERS, which is why everything here is an ordered list rather
%% than a map: a state's `author` is whichever author the merge happened
%% to iterate last, and ties in the promotion are broken by position.
%% merge.js inherits that from JavaScript object key order; this inherits
%% it from the order objects are given in, which must match the order the
%% reference is given (newest first, as git-ssb synced them).
%%
%% JavaScript truthiness is kept where it decides something: sequence 0
%% counts as unset, and an empty repoBranch [] counts as set.
-module(ssb_git_fold).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("ssb/include/ssb.hrl").

-export([object/1,
         fold/1,
         refs/2,
         realname/1]).

-define(DEFAULT_REF, ~"refs/heads/master").

%% A graph object: what the fold needs of one message.
%%   key, author, sequence, timestamp — from the message
%%   links       — every %-string in it, in traversal order
%%   refs        — content.refs as published: [{Name, Hash | null}]
%%   head        — content.head, or undefined
%%   repo_branch — whether content.repoBranch is truthy
-type obj() :: #{key := binary(),
                 author := term(),
                 sequence := term(),
                 timestamp := term(),
                 links := [binary()],
                 refs := [{binary(), binary() | null}],
                 head := binary() | undefined,
                 repo_branch := boolean()}.

-export_type([obj/0]).

%%%===================================================================
%%% API
%%%===================================================================

%% An object from a stored message, or from a {key, value} message in
%% EJSON form (as tools/fold-diff reads them).
object(#message{id = Key, author = Author, sequence = Seq,
              timestamp = Ts, previous = Prev, content = Content}) ->
    object(Key, Author, Seq, Ts, [Prev, Content], Content);
object({Props}) when is_list(Props) ->
    Key = ?pgv(~"key", Props),
    {Value} = Walk = ?pgv(~"value", Props),
    %% walk the value as the object it is: a bare proplist is a list of
    %% 2-tuples, which msg_ids/2 rightly does not look inside
    object(Key, ?pgv(~"author", Value), ?pgv(~"sequence", Value),
         ?pgv(~"timestamp", Value), Walk, ?pgv(~"content", Value)).

object(Key, Author, Seq, Ts, Walk, Content) ->
    CProps = case Content of
                 {P} when is_list(P) -> P;
                 _                   -> []
             end,
    #{key         => Key,
      author      => Author,
      sequence    => Seq,
      timestamp   => Ts,
      links       => msg_ids(Walk),
      refs        => case ?pgv(~"refs", CProps) of
                         {Refs} when is_list(Refs) ->
                             [{N, hash_or_null(H)} || {N, H} <- Refs,
                                                       is_binary(N)];
                         _ ->
                             []
                     end,
      head        => case ?pgv(~"head", CProps) of
                         H when is_binary(H) -> H;
                         _                   -> undefined
                     end,
      repo_branch => truthy(?pgv(~"repoBranch", CProps))}.

%% The repo's refs and HEAD from its objects, in the order the reference
%% is given them: the repo message first, then its updates newest first.
%%   #{refs => [{Name, Hash}], head => Name}
%% Refs are unique by name (the first wins, as pull.unique does).
fold(Objs) ->
    Final = reduce(Objs),
    #{refs => unique([{maps:get(name, R), maps:get(hash, R)}
                      || R <- maps:get(refs, Final)]),
      head => maps:get(head, Final)}.

%% A fork's refs: its own, then whatever its upstream has under names it
%% does not (ssb-git-repo's Repo.refs, with inherited: true).  HEAD is the
%% fork's own.
refs(Own, Upstreams) ->
    #{refs := Refs} = Own,
    Inherited = lists:append([R || #{refs := R} <- Upstreams]),
    Own#{refs => unique(Refs ++ Inherited)}.

%%%===================================================================
%%% kvgraph reduceRight
%%%===================================================================

reduce(Objs) ->
    Keys = [maps:get(key, O) || O <- Objs],
    InGraph = maps:from_list([{K, true} || K <- Keys]),
    ById = maps:from_list([{maps:get(key, O), O} || O <- Objs]),
    Links = maps:from_list(
              [{K, dedup([L || L <- Ls, L =/= K, maps:is_key(L, InGraph)])}
               || #{key := K, links := Ls} <- Objs]),
    %% backlinks(X): the objects linking to X, in the order they were added
    Back = lists:foldl(
             fun(K, Acc) ->
                     lists:foldl(fun(L, A) ->
                                         maps:update_with(L, fun(V) -> V ++ [K] end,
                                                          [K], A)
                                 end, Acc, maps:get(K, Links))
             end, #{}, Keys),
    Roots = [K || K <- Keys, maps:get(K, Links) =:= []],
    {States, _} = lists:mapfoldl(fun(R, Memo) -> state(R, ById, Back, Memo) end,
                                 #{}, Roots),
    merge(States, none).

state(K, ById, Back, Memo) ->
    case Memo of
        #{K := S} ->
            {S, Memo};
        _ ->
            {Above, Memo1} =
                lists:mapfoldl(fun(C, M) -> state(C, ById, Back, M) end,
                               Memo, maps:get(K, Back, [])),
            S = merge(Above, maps:get(K, ById)),
            {S, Memo1#{K => S}}
    end.

%%%===================================================================
%%% merge.js
%%%===================================================================
%%
%% A state is #{refs, ru, head, author, sequence}.  refs is the list of ref
%% objects (each with a hash); ru, merge.js's refUpdates, is an ordered
%% [{Name, Index}] where Index is a 0-based position in refs, or -1 for a
%% name deleted or left without a value.

merge(States, Msg) ->
    O0 = #{refs => [], ru => [], head => states_head(States),
           author => undefined, sequence => undefined},
    O1 = lists:foldl(fun merge_ref/2, O0, refs_updates(States)),
    O2 = case Msg of
             none -> promote_conflict_bases(O1);
             _    -> apply_msg(Msg, O1)
         end,
    choose_head(Msg, O2).

%% refsUpdates: [{Name, [{Author, [{Sequence, Ref | null}]}]}], every
%% level in first-seen order.
refs_updates(States) ->
    lists:foldl(
      fun(#{refs := Refs, ru := RU, author := Author, sequence := Seq}, Acc) ->
              lists:foldl(
                fun({Name, I}, A) ->
                        Ref = case I < 0 of
                                  true  -> null;
                                  false -> lists:nth(I + 1, Refs)
                              end,
                        kv_update(Name,
                                  fun(Authors) ->
                                          kv_update(Author,
                                                    fun(Us) -> Us ++ [{Seq, Ref}] end,
                                                    [], Authors)
                                  end, [], A)
                end, Acc, RU)
      end, [], States).

%% The first truthy head, unless two states disagree, in which case none.
states_head(States) ->
    states_head(States, undefined).

states_head([], Head) ->
    Head;
states_head([#{head := H} | Rest], Head) ->
    case truthy(H) of
        false -> states_head(Rest, Head);
        true when Head =/= undefined, Head =/= H -> undefined;
        true -> states_head(Rest, H)
    end.

merge_ref({Name, Authors}, O) ->
    {Items, O1} =
        lists:foldl(
          fun({Author, [{S0, R0} | Rest]}, {Its, Ox}) ->
                  {MaxSeq, MaxRef} =
                      lists:foldl(fun({S, R}, {MS, MR}) ->
                                          case gt(S, MS) of
                                              true  -> {S, R};
                                              false -> {MS, MR}
                                          end
                                  end, {S0, R0}, Rest),
                  Its1 = case MaxRef of
                             null -> Its;
                             _    -> Its ++ [MaxRef]
                         end,
                  {Its1, Ox#{author => Author, sequence => MaxSeq}}
          end, {[], O}, Authors),
    case Items of
        []    -> append_ref(Name, null, O1);
        [One] -> append_ref(Name, One, O1);
        _ ->
            lists:foldl(
              fun(Ref, Oy) ->
                      RefName = case maps:get(realname, Ref, undefined) of
                                    undefined -> maps:get(name, Ref);
                                    Real      -> Real
                                end,
                      #{key := LinkKey} = maps:get(link, Ref),
                      append_ref(conflict_name(RefName, LinkKey),
                                 #{realname => maps:get(name, Ref),
                                   conflict => true,
                                   hash     => maps:get(hash, Ref),
                                   link     => maps:get(link, Ref)},
                                 Oy)
              end, O1, Items)
    end.

%% refs/heads/foo -> refs/heads/%<key>/foo; a name not under refs/<x> is
%% left alone (the regex does not match).
conflict_name(Name, LinkKey) ->
    case binary:split(Name, ~"/") of
        [~"refs", Rest] ->
            case binary:split(Rest, ~"/") of
                [Kind, Tail] -> <<"refs/", Kind/binary, "/", LinkKey/binary,
                                  "/", Tail/binary>>;
                [Kind]       -> <<"refs/", Kind/binary, "/", LinkKey/binary>>
            end;
        _ ->
            Name
    end.

%% refs/heads/%<key>.sha256/master -> {ok, refs/heads/master}, the name
%% conflict_name/2 made it from; error for a name that is not a conflict
%% branch.
realname(Name) ->
    case binary:split(Name, <<"/">>, [global]) of
        [~"refs", Kind, <<"%", _/binary>> = Key | Tail] ->
            case binary:longest_common_suffix([Key, ~".sha256"]) of
                7 when Tail =/= [] ->
                    {ok, iolist_to_binary(lists:join(<<"/">>, [~"refs", Kind | Tail]))};
                7 ->
                    {ok, <<"refs/", Kind/binary>>};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% merge.js appendRef: a ref with a hash is pushed and indexed, anything
%% else records the name as valueless (-1).
append_ref(Name, Ref, #{refs := Refs, ru := RU} = O) ->
    case is_map(Ref) andalso truthy(maps:get(hash, Ref, undefined)) of
        true ->
            O#{refs => Refs ++ [Ref#{name => Name}],
               ru   => kv_store(Name, length(Refs), RU)};
        false ->
            O#{ru => kv_store(Name, -1, RU)}
    end.

apply_msg(Msg, O) ->
    #{refs := MsgRefs, head := MsgHead, author := MsgAuthor,
      sequence := MsgSeq} = Msg,
    O1 = lists:foldl(
           fun({Name, Hash}, Ox = #{ru := RU}) ->
                   case kv_has(Name, RU) of
                       true  -> Ox;
                       false -> append_ref(Name, #{hash => Hash, link => Msg}, Ox)
                   end
           end, O, MsgRefs),
    O2 = case truthy(maps:get(head, O1)) of
             true  -> O1;
             false -> O1#{head => MsgHead}
         end,
    O3 = case truthy(maps:get(author, O2)) of
             true  -> O2;
             false -> O2#{author => MsgAuthor}
         end,
    case truthy(maps:get(sequence, O3)) of
        true  -> O3;
        false -> O3#{sequence => MsgSeq}
    end.

%% At the top only: a conflict whose plain name has no entry at all gets
%% one of its branches renamed to it.
promote_conflict_bases(#{refs := Refs} = O) ->
    InConflict = lists:foldl(
                   fun(#{conflict := true, realname := Real} = R, Acc) ->
                           kv_update(Real, fun(Rs) -> Rs ++ [R] end, [], Acc);
                      (_, Acc) ->
                           Acc
                   end, [], Refs),
    lists:foldl(fun promote/2, O, InConflict).

promote({Name, Candidates}, #{refs := Refs, ru := RU} = O) ->
    case kv_has(Name, RU) of
        true ->
            O;
        false ->
            Winner = lists:last(lists:sort(fun(A, B) -> compare_refs(A, B) =< 0 end,
                                           Candidates)),
            WinnerName = maps:get(name, Winner),
            case kv_get(WinnerName, RU) of
                undefined ->
                    O;
                I ->
                    RU1 = kv_delete(WinnerName, kv_store(Name, I, RU)),
                    Promoted = maps:remove(realname,
                                           (lists:nth(I + 1, Refs))#{name => Name}),
                    O#{refs => set_nth(I + 1, Promoted, Refs), ru => RU1}
            end
    end.

%% compareRefs: an update that set repoBranch sorts after one that did
%% not, then by claimed timestamp; anything non-numeric compares equal
%% (NaN in the original).
compare_refs(#{link := A}, #{link := B}) ->
    case b2i(maps:get(repo_branch, A)) - b2i(maps:get(repo_branch, B)) of
        0 ->
            case {maps:get(timestamp, A), maps:get(timestamp, B)} of
                {Ta, Tb} when is_number(Ta), is_number(Tb) -> Ta - Tb;
                _                                           -> 0
            end;
        D ->
            D
    end.

%% A message's own head stands only if it named one and it still has a
%% value; at the top there is no message, so it is always recomputed.
choose_head(Msg, #{head := Head, refs := Refs, ru := RU} = O) ->
    Keep = Msg =/= none
        andalso truthy(maps:get(head, Msg))
        andalso truthy(Head)
        andalso not is_neg(kv_get(Head, RU)),
    case Keep of
        true ->
            O;
        false ->
            Default = case kv_get(?DEFAULT_REF, RU) of
                          I when is_integer(I), I >= 0 -> ?DEFAULT_REF;
                          _ ->
                              case Refs of
                                  [] -> ?DEFAULT_REF;
                                  _  -> maps:get(name, lists:last(Refs))
                              end
                      end,
            O#{head => Default}
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Every string beginning with % among the values of a term, in order —
%% kvgraph's each(), narrowed to the only strings that can be graph keys.
msg_ids(Term) ->
    lists:reverse(msg_ids(Term, [])).

msg_ids(<<"%", _/binary>> = B, Acc)      -> [B | Acc];
msg_ids({Props}, Acc) when is_list(Props) ->
    lists:foldl(fun({_K, V}, A) -> msg_ids(V, A);
                   (_, A)       -> A
                end, Acc, Props);
msg_ids(L, Acc) when is_list(L)          -> lists:foldl(fun msg_ids/2, Acc, L);
msg_ids(_, Acc)                          -> Acc.

hash_or_null(H) when is_binary(H) -> H;
hash_or_null(_)                   -> null.

%% JavaScript truthiness, for the values that appear here.
truthy(undefined) -> false;
truthy(null)      -> false;
truthy(false)     -> false;
truthy(0)         -> false;
truthy(<<>>)      -> false;
truthy(_)         -> true.

gt(A, B) when is_number(A), is_number(B) -> A > B;
gt(_, _)                                 -> false.

is_neg(I) when is_integer(I) -> I < 0;
is_neg(_)                    -> false.

b2i(true)  -> 1;
b2i(false) -> 0.

dedup(L) ->
    dedup(L, #{}).

dedup([], _)       -> [];
dedup([X | T], S) ->
    case S of
        #{X := _} -> dedup(T, S);
        _         -> [X | dedup(T, S#{X => true})]
    end.

unique(Pairs) ->
    unique(Pairs, #{}).

unique([], _) -> [];
unique([{N, _} = P | T], S) ->
    case S of
        #{N := _} -> unique(T, S);
        _         -> [P | unique(T, S#{N => true})]
    end.

set_nth(1, X, [_ | T]) -> [X | T];
set_nth(N, X, [H | T]) -> [H | set_nth(N - 1, X, T)].

%% An ordered key-value list with JavaScript object semantics: assigning
%% an existing key keeps its position, a new key goes at the end.
kv_store(K, V, L) ->
    case lists:keymember(K, 1, L) of
        true  -> lists:keyreplace(K, 1, L, {K, V});
        false -> L ++ [{K, V}]
    end.

kv_update(K, F, Init, L) ->
    case lists:keyfind(K, 1, L) of
        {K, V} -> lists:keyreplace(K, 1, L, {K, F(V)});
        false  -> L ++ [{K, F(Init)}]
    end.

kv_get(K, L) ->
    case lists:keyfind(K, 1, L) of
        {K, V} -> V;
        false  -> undefined
    end.

kv_has(K, L)    -> lists:keymember(K, 1, L).
kv_delete(K, L) -> lists:keydelete(K, 1, L).

%%%===================================================================
%%% Tests: ssb-git 0.5.0 test/repo.js, case for case
%%%===================================================================
-ifdef(TEST).

obj(Key, Author, Seq, Links, Refs) ->
    #{key => Key, author => Author, sequence => Seq, timestamp => undefined,
      links => Links, refs => Refs, head => undefined,
      repo_branch => false}.

refs_of(Objs) ->
    lists:sort(maps:get(refs, fold(Objs))).

%% The reference adds objects oldest first in its own tests; the fold takes
%% them in whatever order it is handed, so these keep that order.
reference_test_() ->
    O1 = obj(~"%1", ~"@a", 0, [], [{~"refs/heads/foo", ~"1"}]),
    %% repoBranch at value level in the original ("TODO: make it work
    %% without this") — any link counts, wherever it sits
    O2 = obj(~"%2", ~"@a", 1, [~"%1"], [{~"refs/heads/master", ~"2"},
                                        {~"refs/heads/foo", ~"3"}]),
    O3 = (obj(~"%3", ~"@b", 0, [~"%1"], [{~"refs/heads/foo", ~"4"}]))
         #{repo_branch => true},
    O4 = (obj(~"%4", ~"@c", 2, [~"%2"], [{~"refs/heads/foo", ~"5"}]))
         #{repo_branch => true},
    O5 = (obj(~"%5", ~"@c", 0, [~"%3", ~"%4"], [{~"refs/heads/foo", ~"6"}]))
         #{repo_branch => true},
    [{"empty repo",
      ?_assertEqual(#{refs => [], head => ~"refs/heads/master"}, fold([]))},
     {"add a commit",
      [?_assertEqual(~"refs/heads/foo", maps:get(head, fold([O1]))),
       ?_assertEqual([{~"refs/heads/foo", ~"1"}], refs_of([O1]))]},
     {"update branch and add a new branch",
      [?_assertEqual(~"refs/heads/master", maps:get(head, fold([O1, O2]))),
       ?_assertEqual([{~"refs/heads/foo", ~"3"},
                      {~"refs/heads/master", ~"2"}], refs_of([O1, O2]))]},
     {"introduce a conflict",
      ?_assertEqual([{~"refs/heads/%2/foo", ~"3"},
                     {~"refs/heads/%3/foo", ~"4"},
                     {~"refs/heads/foo", ~"1"},
                     {~"refs/heads/master", ~"2"}], refs_of([O1, O2, O3]))},
     {"extend conflict branch",
      ?_assertEqual([{~"refs/heads/%3/foo", ~"4"},
                     {~"refs/heads/%4/foo", ~"5"},
                     {~"refs/heads/foo", ~"1"},
                     {~"refs/heads/master", ~"2"}], refs_of([O1, O2, O3, O4]))},
     {"resolve conflict",
      ?_assertEqual([{~"refs/heads/foo", ~"6"},
                     {~"refs/heads/master", ~"2"}],
                    refs_of([O1, O2, O3, O4, O5]))}].

conflict_with_link_may_become_base_test() ->
    P1 = obj(~"%1", ~"@a", undefined, [], [{~"refs/heads/master", ~"1"}]),
    P2 = (obj(~"%2", ~"@b", undefined, [~"%1"],
              [{~"refs/heads/master", ~"2"}]))#{repo_branch => true},
    %% an old client, pushing without repoBranch: a second root
    P3 = obj(~"%3", ~"@c", undefined, [], [{~"refs/heads/master", ~"3"}]),
    ?assertEqual([{~"refs/heads/%3/master", ~"3"},
                  {~"refs/heads/master", ~"2"}], refs_of([P1, P2, P3])).

%% A later update by the same author supersedes an earlier one; null
%% deletes the branch.
same_author_and_deletion_test() ->
    R  = obj(~"%r", ~"@a", 1, [], []),
    U1 = obj(~"%u1", ~"@a", 2, [~"%r"], [{~"refs/heads/master", ~"1"},
                                         {~"refs/heads/topic", ~"t"}]),
    U2 = obj(~"%u2", ~"@a", 3, [~"%r", ~"%u1"],
             [{~"refs/heads/master", ~"2"}, {~"refs/heads/topic", null}]),
    ?assertEqual(#{refs => [{~"refs/heads/master", ~"2"}],
                   head => ~"refs/heads/master"},
                 fold([R, U2, U1])).

object_from_message_test() ->
    Msg = #message{id = ~"%u", author = ~"@a", sequence = 7, timestamp = 99,
                   previous = ~"%prev",
                   content = {[{~"type", ~"git-update"},
                               {~"repo", ~"%r"},
                               {~"refs", {[{~"refs/heads/b", ~"bb"},
                                           {~"refs/heads/a", null}]}},
                               {~"repoBranch", []},
                               {~"mentions", [{[{~"link", ~"%m"}]}]}]}},
    ?assertEqual(#{key => ~"%u", author => ~"@a", sequence => 7,
                   timestamp => 99,
                   links => [~"%prev", ~"%r", ~"%m"],
                   %% published order kept; an empty repoBranch is truthy
                   refs => [{~"refs/heads/b", ~"bb"}, {~"refs/heads/a", null}],
                   head => undefined, repo_branch => true},
                 object(Msg)).

%% Both entry points must find the same links: the view builds objects from
%% stored messages, fold-diff from their JSON, and a difference between the
%% two is a difference between what is served and what was checked.
object_from_json_matches_message_test() ->
    Content = {[{~"type", ~"git-update"}, {~"repo", ~"%r"},
                {~"refsBranch", [~"%b"]},
                {~"refs", {[{~"refs/heads/master", ~"aa"}]}}]},
    Msg = #message{id = ~"%u", author = ~"@a", sequence = 2, timestamp = 5,
                   previous = ~"%prev", content = Content},
    Json = {[{~"key", ~"%u"},
             {~"value", {[{~"previous", ~"%prev"}, {~"author", ~"@a"},
                          {~"sequence", 2}, {~"timestamp", 5},
                          {~"hash", ~"sha256"}, {~"content", Content},
                          {~"signature", ~"sig"}]}}]},
    ?assertEqual([~"%prev", ~"%r", ~"%b"], maps:get(links, object(Msg))),
    ?assertEqual(object(Msg), object(Json)).

conflict_name_test_() ->
    [?_assertEqual(~"refs/heads/%k/foo/bar",
                   conflict_name(~"refs/heads/foo/bar", ~"%k")),
     ?_assertEqual(~"refs/tags/%k/v1", conflict_name(~"refs/tags/v1", ~"%k")),
     ?_assertEqual(~"HEAD", conflict_name(~"HEAD", ~"%k"))].

fork_inherits_upstream_refs_test() ->
    Own = #{refs => [{~"refs/heads/master", ~"f"}], head => ~"refs/heads/master"},
    Up  = #{refs => [{~"refs/heads/master", ~"u"}, {~"refs/heads/dev", ~"d"}],
            head => ~"refs/heads/dev"},
    ?assertEqual(#{refs => [{~"refs/heads/master", ~"f"},
                            {~"refs/heads/dev", ~"d"}],
                   head => ~"refs/heads/master"},
                 refs(Own, [Up])).

realname_test_() ->
    K = ~"%AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=.sha256",
    [?_assertEqual({ok, ~"refs/heads/master"},
                   realname(<<"refs/heads/", K/binary, "/master">>)),
     ?_assertEqual({ok, ~"refs/heads/a/b"},
                   realname(<<"refs/heads/", K/binary, "/a/b">>)),
     ?_assertEqual(error, realname(~"refs/heads/master")),
     ?_assertEqual(error, realname(~"refs/heads/%notakey/master"))].

-endif.
