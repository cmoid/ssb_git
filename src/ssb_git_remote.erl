%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% git-remote-ssb: the git remote helper for ssb:// URLs.
%%
%% git runs `git-remote-ssb <remote> <url>` with GIT_DIR set, writes
%% commands to our stdin one per line, and reads replies from our stdout;
%% a blank line ends each reply, and a blank line from git ends the
%% session.  See gitremote-helpers(7).
%%
%%   capabilities  -> the commands we support
%%   list          -> "<sha1> <ref>" lines, "@<ref> HEAD" for the symref
%%   fetch <sha1> <ref>   (batched, ended by a blank line)
%%   push <src>:<dst>     (batched, ended by a blank line)
%%   option <name> <value>
%%
%% The chain only runs one way: git -> this helper -> the node.  The
%% helper owns git's object format (git pack-objects / git index-pack, run
%% against GIT_DIR); the node owns SSB state, blobs and publishing.
%%
%% The session parses the URL, connects to the node, confirms the repo
%% exists, and answers `capabilities`, `option`, `list` (from git.refs, the
%% ssb_git_fold of the repo's updates), `fetch` and `push` (ssb_git_push).
%%
%% Fetch takes every pack the repo's updates name (git.packs), skips those
%% this clone has already absorbed ($GIT_DIR/ssb/packs), pulls the rest
%% with blobs.get and feeds each to `git index-pack --stdin --fix-thin`.
%% index-pack recomputes every object hash, so a pack is trusted no
%% further than git trusts any pack, and the published .idx is not read.
%% git then checks the fetched refs are connected, as after any fetch.
-module(ssb_git_remote).

-export([main/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(CAPABILITIES, ["fetch", "push", "option"]).

%% How long fetch waits for packs the node does not hold yet, after
%% asking for them with blobs.want.  SSB_GIT_BLOB_WAIT, in seconds.
-define(BLOB_WAIT_S, 60).
-define(BLOB_POLL_MS, 2000).

main([_Remote, Url]) ->
    case parse_url(Url) of
        {ok, RepoId} ->
            {ok, Peer} = ssb_git_client:connect(),
            case check_repo(Peer, RepoId) of
                ok ->
                    ok = io:setopts(standard_io, [binary]),
                    session(#{peer => Peer, repo => RepoId});
                {error, Why} ->
                    err("~s: ~s", [RepoId, Why]),
                    1
            end;
        error ->
            err("not an ssb repo URL: ~s "
                "(expected ssb://%<message id>.sha256)", [Url]),
            1
    end;
main(_) ->
    err("usage: git-remote-ssb <remote> <url> — git runs this, not you", []),
    2.

%%%===================================================================
%%% The session
%%%===================================================================

%% command/1 parses; it answers {reply, Lines} for a reply git reads to a
%% blank line (capabilities), {line, L} for a one-line answer (option),
%% and `list` for the one command that needs the node.

session(St) ->
    case io:get_line(standard_io, "") of
        eof ->
            0;
        {error, Reason} ->
            err("reading from git: ~p", [Reason]),
            1;
        Line ->
            case command(string:trim(Line, trailing, "\r\n")) of
                done             -> 0;
                {reply, Lines}   -> reply(Lines), session(St);
                {line, L}        -> io:put_chars(standard_io, [L, $\n]),
                                    session(St);
                list ->
                    case list(St) of
                        {ok, Lines}     -> reply(Lines), session(St);
                        {error, Reason} -> err("list: ~p", [Reason]), 1
                    end;
                {push, Spec} ->
                    case push_batch([Spec]) of
                        {ok, Specs} ->
                            reply(push_replies(
                                    ssb_git_push:push(maps:get(peer, St),
                                                      maps:get(repo, St), Specs),
                                    Specs)),
                            session(St);
                        {error, Reason} ->
                            err("push: ~p", [Reason]), 1
                    end;
                {fetch, Sha} ->
                    case fetch_batch([Sha]) of
                        {ok, Shas} ->
                            case fetch(St, Shas) of
                                ok              -> reply([]), session(St);
                                {error, Reason} -> err("fetch: ~s", [Reason]), 1
                            end;
                        {error, Reason} ->
                            err("fetch: ~p", [Reason]), 1
                    end;
                {fail, Fmt, Arg} -> err(Fmt, Arg), 1
            end
    end.

%% "<hash> <ref>" for every ref, then "@<ref> HEAD" when HEAD names one of
%% them.  `list for-push` gets the same answer: there is no separate view
%% of what a push would update.
list(#{peer := Peer, repo := Repo}) ->
    case ssb_git_client:call(Peer, [~"git", ~"refs"], [{[{~"repo", Repo}]}]) of
        {ok, #{~"refs" := Refs, ~"head" := Head}} ->
            {ok, list_lines([{N, H} || #{~"name" := N, ~"hash" := H} <- Refs],
                            Head)};
        {ok, Other} ->
            {error, {unexpected, Other}};
        {error, _} = Err ->
            Err
    end.

list_lines(Refs, Head) ->
    [[H, $\s, N] || {N, H} <- Refs]
        ++ [[$@, Head, " HEAD"] || lists:keymember(Head, 1, Refs)].

%% A blank line from git outside a batch ends the session.
command(<<>>) ->
    done;
command(<<"capabilities">>) ->
    {reply, ?CAPABILITIES};
command(<<"option ", _/binary>>) ->
    %% Options are hints (verbosity, progress, depth); "unsupported" is a
    %% legal answer to every one of them, and git carries on.  The answer
    %% is ONE line: unlike capabilities and list, no blank line ends it,
    %% and sending one puts every later reply a line out of step.
    {line, "unsupported"};
command(<<"list">>) ->
    list;
command(<<"list ", _/binary>>) ->
    list;
command(<<"fetch ", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Sha, _Ref] when byte_size(Sha) =:= 40 -> {fetch, Sha};
        _ -> {fail, "bad fetch line from git: fetch ~s", [Rest]}
    end;
command(<<"push ", Rest/binary>>) ->
    %% [+]<src>:<dst>; the + (force) changes nothing here — a push that is
    %% not a fast-forward is published all the same, and the fold shows it
    case binary:split(strip_plus(Rest), <<":">>) of
        [Src, Dst] when Dst =/= <<>> -> {push, {Src, Dst}};
        _ -> {fail, "bad push line from git: push ~s", [Rest]}
    end;
command(Other) ->
    {fail, "unknown command from git: ~s", [Other]}.

strip_plus(<<"+", R/binary>>) -> R;
strip_plus(R)                 -> R.

%% The rest of a push batch, ended by a blank line, as fetch_batch.
push_batch(Acc) ->
    case io:get_line(standard_io, "") of
        eof             -> {error, eof_in_push_batch};
        {error, _} = E  -> E;
        Line ->
            case command(string:trim(Line, trailing, "\r\n")) of
                done          -> {ok, lists:reverse(Acc)};
                {push, Spec}  -> push_batch([Spec | Acc]);
                _             -> {error, {not_a_push_line, Line}}
            end
    end.

%% One line per ref git asked for: "ok <dst>" or "error <dst> <why>".  The
%% batch is one update, so every ref has the same outcome.
push_replies(ok, Specs) ->
    [[~"ok ", Dst] || {_, Dst} <- Specs];
push_replies({error, Why}, Specs) ->
    err("push: ~s", [Why]),
    [[~"error ", Dst, $\s, Why] || {_, Dst} <- Specs].

%% The rest of a fetch batch: more `fetch <sha1> <ref>` lines, ended by
%% a blank one.
fetch_batch(Acc) ->
    case io:get_line(standard_io, "") of
        eof             -> {error, eof_in_fetch_batch};
        {error, _} = E  -> E;
        Line ->
            case command(string:trim(Line, trailing, "\r\n")) of
                done         -> {ok, lists:usort(Acc)};
                {fetch, Sha} -> fetch_batch([Sha | Acc]);
                _            -> {error, {not_a_fetch_line, Line}}
            end
    end.

reply(Lines) ->
    io:put_chars(standard_io, [[L, $\n] || L <- Lines] ++ "\n").

%% The repo must be a git-repo message the node holds: git-remote-ssb did
%% the same, and it turns a typo'd URL into an error naming it instead of
%% an empty clone.
check_repo(Peer, RepoId) ->
    case ssb_git_client:call(Peer, [~"get"], [RepoId]) of
        {ok, #{~"content" := #{~"type" := ~"git-repo"}}} ->
            ok;
        {ok, #{~"content" := #{~"type" := Type}}} ->
            {error, io_lib:format("is a ~s message, not a git-repo", [Type])};
        {ok, #{~"content" := C}} when is_binary(C) ->
            {error, "is a private message (private repos are not supported yet)"};
        _ ->
            {error, "repo not found on this node"}
    end.

%%%===================================================================
%%% Fetch
%%%===================================================================

%% ok once every wanted object is in GIT_DIR, {error, Text} otherwise.
%%
%% The record of absorbed packs is only a shortcut: objects can leave a
%% clone (gc after a branch is deleted), so when the shortcut leaves a
%% wanted object missing, every pack is absorbed again before giving up.
fetch(#{peer := Peer, repo := Repo}, Shas) ->
    case ssb_git_local:missing(Shas) of
        [] ->
            ok;
        _ ->
            case packs(Peer, Repo) of
                {ok, Packs} ->
                    Done = ssb_git_local:absorbed(),
                    absorb(Peer, [P || {Id, _} = P <- Packs,
                                       not sets:is_element(Id, Done)]),
                    case {ssb_git_local:missing(Shas), sets:is_empty(Done)} of
                        {[], _}    -> ok;
                        {_, true}  -> gave_up(Shas);
                        {_, false} -> absorb(Peer, Packs),
                                      gave_up(Shas)
                    end;
                {error, Reason} ->
                    {error, io_lib:format("git.packs: ~p", [Reason])}
            end
    end.

gave_up(Shas) ->
    case ssb_git_local:missing(Shas) of
        [] ->
            ok;
        Missing ->
            {error, io_lib:format("no pack this node holds contains ~s",
                                  [lists:join(", ", Missing)])}
    end.

%% [{PackId, Chunks}], oldest update first, each once.  Chunks are the
%% blobs after the first of a pack too big for one (ssb_git_push); the
%% pack is their concatenation, and PackId — the first — names it.
packs(Peer, Repo) ->
    case ssb_git_client:call(Peer, [~"git", ~"packs"], [{[{~"repo", Repo}]}]) of
        {ok, L} when is_list(L) ->
            {ok, dedup([{P, maps:get(~"chunks", E, [])} || #{~"pack" := P} = E <- L])};
        {ok, Other} ->
            {error, {unexpected, Other}};
        {error, _} = Err ->
            Err
    end.

dedup(L) ->
    {Out, _} = lists:foldl(fun(X, {Acc, Seen}) ->
                                   case sets:is_element(X, Seen) of
                                       true  -> {Acc, Seen};
                                       false -> {[X | Acc], sets:add_element(X, Seen)}
                                   end
                           end, {[], sets:new([{version, 2}])}, L),
    lists:reverse(Out).

%% Index every pack it can.  Packs the node lacks are wanted and waited
%% for; a pack index-pack refuses is retried after the others, in case it
%% is thin and its bases came later in the list, until a pass makes no
%% progress.  What is still missing after that is reported, but only the
%% wanted objects decide whether the fetch failed.
absorb(_Peer, []) ->
    ok;
absorb(Peer, Packs0) ->
    {Packs, Bad} = lists:partition(fun({P, Cs}) -> lists:all(fun is_blob/1, [P | Cs]) end,
                                   Packs0),
    [err("~s: its chunk list names something that is not a blob", [P])
     || {P, _} <- Bad],
    Blobs = lists:usort(lists:append([[P | Cs] || {P, Cs} <- Packs])),
    {Have, Lacking} = have(Peer, Blobs),
    Got = sets:from_list(Have ++ wait_for(Peer, Lacking), [{version, 2}]),
    {Ready, Never} = lists:partition(
                       fun({P, Cs}) -> lists:all(fun(B) -> sets:is_element(B, Got) end,
                                                 [P | Cs])
                       end, Packs),
    case Never of
        [] -> ok;
        _  -> err("~b pack(s) not on this node or its peers: ~s",
                  [length(Never), lists:join(" ", [P || {P, _} <- Never])])
    end,
    passes(Ready, Peer).

is_blob(Id) -> ssb_git_local:blob_hash(Id) =/= bad_id.

passes([], _Peer) ->
    ok;
passes(Packs, Peer) ->
    Failed = [P || P <- Packs, index_pack(Peer, P) =/= ok],
    if
        length(Failed) < length(Packs) -> passes(Failed, Peer);
        true -> err("index-pack refused ~b pack(s): ~s",
                    [length(Failed), lists:join(" ", [Id || {Id, _} <- Failed])])
    end.

have(Peer, Blobs) ->
    lists:partition(fun(B) -> has_blob(Peer, B) end, Blobs).

has_blob(Peer, Id) ->
    ssb_git_client:call(Peer, [~"blobs", ~"has"], [Id]) =:= {ok, true}.

%% Ask the node for the lacking blobs, then poll until they land or the
%% wait runs out.  The ones that arrived.
wait_for(_Peer, []) ->
    [];
wait_for(Peer, Lacking) ->
    err("waiting up to ~bs for ~b blob(s) from the network",
        [blob_wait_s(), length(Lacking)]),
    [ssb_git_client:call(Peer, [~"blobs", ~"want"], [P]) || P <- Lacking],
    Deadline = erlang:monotonic_time(millisecond) + blob_wait_s() * 1000,
    poll(Peer, Lacking, [], Deadline).

poll(_Peer, [], Arrived, _Deadline) ->
    Arrived;
poll(Peer, Lacking, Arrived, Deadline) ->
    {Now, Still} = have(Peer, Lacking),
    case Still =/= [] andalso erlang:monotonic_time(millisecond) < Deadline of
        true  -> timer:sleep(?BLOB_POLL_MS),
                 poll(Peer, Still, Now ++ Arrived, Deadline);
        false -> Now ++ Arrived
    end.

blob_wait_s() ->
    case os:getenv("SSB_GIT_BLOB_WAIT") of
        S when is_list(S), S =/= "" ->
            try list_to_integer(S) catch _:_ -> ?BLOB_WAIT_S end;
        _ ->
            ?BLOB_WAIT_S
    end.

%% One pack: fetch its blobs, check each is the blob it claims to be (an
%% error frame from blobs.get arrives looking like data), put them back
%% together, and index it.  index-pack checks the pack's own trailing
%% checksum, so pieces in the wrong order or one missing cannot pass.
index_pack(Peer, {Id, Chunks}) ->
    case get_blobs(Peer, [Id | Chunks], []) of
        {ok, Pack} ->
            Tmp = filename:join(ssb_git_local:state_dir(), "incoming.pack"),
            ok = file:write_file(Tmp, Pack),
            Result = ssb_git_local:git(["index-pack", "--stdin", "--fix-thin"], Tmp),
            _ = file:delete(Tmp),
            case Result of
                {0, _} -> ssb_git_local:record_absorbed(Id), ok;
                {_, _} -> error
            end;
        {error, Reason} ->
            err("~s: ~p", [Id, Reason]),
            error
    end.

get_blobs(_Peer, [], Acc) ->
    {ok, lists:reverse(Acc)};
get_blobs(Peer, [B | Rest], Acc) ->
    case get_blob(Peer, B) of
        {ok, Data}         -> get_blobs(Peer, Rest, [Data | Acc]);
        {error, R}         -> {error, {B, R}}
    end.

get_blob(Peer, Id) ->
    try ssb_peer:fetch_blob(Peer, Id) of
        {ok, Data} ->
            case ssb_git_local:blob_hash(Id) =:= crypto:hash(sha256, Data) of
                true  -> {ok, Data};
                false -> {error, not_the_blob}
            end;
        Other ->
            {error, Other}
    catch
        exit:Reason -> {error, Reason}
    end.

%%%===================================================================
%%% URLs
%%%===================================================================

%% ssb://%<id>.sha256, also ssb:%<id>.sha256 (git-remote-ssb accepted
%% both), and with the leading % written as %25 — the form git-ssb-web
%% printed in links, since % is the escape character in a URL.
parse_url(Url) when is_list(Url) ->
    parse_url(list_to_binary(Url));
parse_url(<<"ssb://", Rest/binary>>) -> msg_id(Rest);
parse_url(<<"ssb:", Rest/binary>>)   -> msg_id(Rest);
parse_url(_)                         -> error.

%%
%% The raw form is tried first: a real id's base64 can itself begin "25".
msg_id(Bin) ->
    case raw_msg_id(Bin) of
        {ok, Id} ->
            {ok, Id};
        error ->
            %% percent_decode throws, rather than returns, on a bad escape
            try uri_string:percent_decode(Bin) of
                Decoded when is_binary(Decoded), Decoded =/= Bin ->
                    raw_msg_id(Decoded);
                _ ->
                    error
            catch _:_ ->
                    error
            end
    end.

raw_msg_id(<<"%", B64:44/binary, ".sha256">> = Id) ->
    try base64:decode(B64) of
        Hash when byte_size(Hash) =:= 32 -> {ok, Id};
        _                                -> error
    catch _:_ -> error
    end;
raw_msg_id(_) ->
    error.

err(Fmt, Args) ->
    io:format(standard_error, "git-remote-ssb: " ++ Fmt ++ "~n", Args).

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

-define(SHA, ~"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678").
-define(ID, "%n92DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU=.sha256").

parse_url_test_() ->
    Id = list_to_binary(?ID),
    [?_assertEqual({ok, Id}, parse_url("ssb://" ?ID)),
     ?_assertEqual({ok, Id}, parse_url("ssb:" ?ID)),
     %% git-ssb-web's link form: % as %25, and the base64 escaped too
     ?_assertEqual({ok, Id},
                   parse_url("ssb://%25n92DiQh7ietE%2BR%2BX%2FI403LQoyf2Dt"
                             "R3WQfCkDKlheQU%3D.sha256")),
     %% a raw id whose base64 starts "25" is not mistaken for an escape
     ?_assertEqual({ok, ~"%252DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU=.sha256"},
                   parse_url("ssb://%252DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU="
                             ".sha256")),
     %% a malformed escape is a bad URL, not a crash
     ?_assertEqual(error, parse_url("ssb://%25zz.sha256")),
     ?_assertEqual(error, parse_url("https://example.com/" ?ID)),
     ?_assertEqual(error, parse_url("ssb://@EMovhfIrFk4NihAKnRNhrfRaqIhBv1Wj"
                                    "8pTxJNgvCCY=.ed25519")),
     ?_assertEqual(error, parse_url("ssb://%short.sha256")),
     ?_assertEqual(error, parse_url("ssb://"))].

command_test_() ->
    [?_assertEqual(done, command(<<>>)),
     ?_assertEqual({reply, ?CAPABILITIES}, command(<<"capabilities">>)),
     ?_assertEqual({line, "unsupported"}, command(<<"option verbosity 1">>)),
     ?_assertEqual(list, command(<<"list">>)),
     ?_assertEqual(list, command(<<"list for-push">>)),
     ?_assertMatch({fail, _, _}, command(<<"listen">>)),
     ?_assertEqual({fetch, ?SHA}, command(<<"fetch ", ?SHA/binary, " refs/heads/master">>)),
     ?_assertMatch({fail, _, _}, command(<<"fetch abc refs/heads/master">>)),
     ?_assertEqual({push, {~"refs/heads/x", ~"refs/heads/y"}},
                   command(<<"push +refs/heads/x:refs/heads/y">>)),
     ?_assertEqual({push, {<<>>, ~"refs/heads/gone"}}, command(<<"push :refs/heads/gone">>)),
     ?_assertMatch({fail, _, _}, command(<<"push refs/heads/x">>)),
     ?_assertMatch({fail, _, _}, command(<<"connect git-upload-pack">>))].

list_lines_test_() ->
    Refs = [{~"refs/heads/master", ~"aa"}, {~"refs/heads/%k/master", ~"bb"}],
    [?_assertEqual([~"aa refs/heads/master", ~"bb refs/heads/%k/master",
                    ~"@refs/heads/master HEAD"],
                   [iolist_to_binary(L) || L <- list_lines(Refs, ~"refs/heads/master")]),
     %% HEAD naming a ref that does not exist is left out, not sent dangling
     ?_assertEqual([~"aa refs/heads/master"],
                   [iolist_to_binary(L)
                    || L <- list_lines([hd(Refs)], ~"refs/heads/gone")]),
     ?_assertEqual([], list_lines([], ~"refs/heads/master"))].

dedup_test() ->
    ?assertEqual([~"a", ~"b", ~"c"], dedup([~"a", ~"b", ~"a", ~"c", ~"b"])),
    ?assertEqual([{~"a", []}, {~"b", [~"c"]}],
                 dedup([{~"a", []}, {~"b", [~"c"]}, {~"a", []}])).

-endif.
