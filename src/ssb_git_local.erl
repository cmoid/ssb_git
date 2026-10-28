%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% The local side of the remote helper: running git against GIT_DIR, and
%% the helper's own state under GIT_DIR/ssb.  Shared by fetch
%% (ssb_git_remote) and push (ssb_git_push).
-module(ssb_git_local).

-export([git/1, git/2, git_in/2, git_quiet/1,
         missing/1, present/1,
         state_dir/0, absorbed/0, record_absorbed/1,
         blob_id/1, blob_hash/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%%===================================================================
%%% git
%%%===================================================================

%% {ExitStatus, Stdout} of git with Args, stdin from File if given.
%% git's stderr is ours, which is git's: index-pack's complaints reach
%% the user as they would from any fetch.
git(Args) ->
    git(Args, undefined).

git(Args, StdinFile) ->
    Git = os:find_executable("git"),
    {Exe, Argv} = case StdinFile of
                      undefined -> {Git, Args};
                      File -> {"/bin/sh",
                               ["-c", "f=$1; shift; exec \"$@\" < \"$f\"",
                                "sh", File, Git | Args]}
                  end,
    Port = open_port({spawn_executable, Exe},
                     [{args, Argv}, binary, exit_status, use_stdio, hide]),
    collect(Port, []).

%% As git/1 with git's stderr discarded: for questions whose "no" git
%% reports as an error (is this a repository? does this remote exist?).
git_quiet(Args) ->
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", "exec \"$@\" 2>/dev/null", "sh",
                              os:find_executable("git") | Args]},
                      binary, exit_status, use_stdio, hide]),
    collect(Port, []).

%% As git/2, with Stdin (iodata) as git's standard input.  A port cannot
%% close its child's stdin without closing the port, so it goes through a
%% file.
git_in(Args, Stdin) ->
    File = filename:join(state_dir(),
                         "stdin." ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:write_file(File, Stdin),
    try git(Args, File)
    after _ = file:delete(File)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}}        -> collect(Port, [Acc, D]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    end.

%% Which of Shas GIT_DIR does not hold.
missing(Shas) ->
    [S || S <- Shas, element(1, git(["cat-file", "-e", S])) =/= 0].

%% Which of Shas GIT_DIR holds, in one git call however many there are.
present([]) ->
    [];
present(Shas) ->
    {0, Out} = git_in(["cat-file", "--batch-check=%(objectname)"],
                      [[S, $\n] || S <- Shas]),
    %% a missing object is reported as "<name> missing"
    [L || L <- binary:split(Out, <<"\n">>, [global, trim_all]),
          binary:match(L, <<" ">>) =:= nomatch].

%%%===================================================================
%%% GIT_DIR/ssb
%%%===================================================================

%% git sets GIT_DIR for a remote helper; ssb/ under it is ours.
state_dir() ->
    Dir = filename:join(case os:getenv("GIT_DIR") of
                            D when is_list(D), D =/= "" -> D;
                            _                           -> ".git"
                        end, "ssb"),
    ok = filelib:ensure_path(Dir),
    Dir.

%% Pack blob ids whose objects are already in this clone — indexed by a
%% fetch, or packed here by a push — one per line.  Keyed by the blob, not
%% the repo: a pack is the same objects whichever repo or fork named it.
absorbed() ->
    case file:read_file(filename:join(state_dir(), "packs")) of
        {ok, Bin} ->
            sets:from_list(binary:split(Bin, <<"\n">>, [global, trim_all]),
                           [{version, 2}]);
        {error, _} ->
            sets:new([{version, 2}])
    end.

record_absorbed(Id) ->
    ok = file:write_file(filename:join(state_dir(), "packs"), [Id, $\n],
                         [append]).

%%%===================================================================
%%% Blob ids
%%%===================================================================

%% The SSB blob id of Bytes.
blob_id(Bytes) ->
    <<"&", (base64:encode(crypto:hash(sha256, Bytes)))/binary, ".sha256">>.

%% The sha256 a blob id names, or bad_id.
blob_hash(<<"&", B64:44/binary, ".sha256">>) ->
    try base64:decode(B64) catch _:_ -> bad_id end;
blob_hash(_) ->
    bad_id.

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

blob_hash_test_() ->
    H = crypto:hash(sha256, ~"x"),
    [?_assertEqual(H, blob_hash(<<"&", (base64:encode(H))/binary, ".sha256">>)),
     ?_assertEqual(H, blob_hash(blob_id(~"x"))),
     ?_assertEqual(bad_id, blob_hash(~"%notablob.sha256"))].

-endif.
