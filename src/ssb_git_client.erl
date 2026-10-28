%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% The client side of ssb_git: connect to a running erlbutt node as its
%% owner and call its RPCs.  Used by git-ssb and git-remote-ssb, which run
%% in their own short-lived VM (bin/git-ssb), never inside the node.
%%
%% The node is found through SSB_HOME, which bin/git-ssb always sets to
%% the release root.  The beams come from that release, so the client
%% modules (ssb_peer, keys, config, ...) are always the node's own version;
%% the identity and data directory are then found exactly as the node finds
%% them (ssb_paths), and we connect over SHS with the node's own key — the
%% same arrangement as sbutt.
%%
%% Everything from release_root/0 down to start_keys/0 is a copy of
%% sbutt.escript's bootstrap.  It belongs in erlbutt as a module any client
%% can call; until then the two copies must be kept in step.
-module(ssb_git_client).

-export([connect/0,
         call/3,
         add_blob/2,
         stream/3,
         stream_each/5,
         decode/1]).

-define(DEFAULT_PORT, 8008).

%% How long stream_each waits for the NEXT frame — not for the whole
%% stream, which may legitimately run for minutes (sbutt's hist, same).
-define(STREAM_IDLE_MS, 30000).

%% {ok, Peer}, or halts with a message on stderr: there is nothing a
%% caller could do with a node it cannot reach except say so.
connect() ->
    Root = release_root(),
    add_release_paths(Root),
    application:set_env(ssb, release_root, Root),
    {ok, _} = config:start_link(ssb_paths:release_cfg()),
    start_keys(),
    {ok, _} = network_id_cache:start_link(),
    %% ssb_peer is a full peer: the node answers back with blob
    %% createWants, which the connection tries to serve, so blobs must be
    %% running or the connection dies before any reply (see sbutt).
    {ok, _} = blobs:start_link(),
    RemotePk = base64:decode(keys:pub_key()),
    case ssb_peer:start("localhost", port(), RemotePk) of
        {ok, Peer} ->
            {ok, Peer};
        Err ->
            die("cannot connect to erlbutt on port ~p: ~p", [port(), Err])
    end.

%% One async call.  {ok, DecodedJson} | {error, Reason}.  An error frame
%% from the node reaches ssb_peer as an ordinary body, the muxrpc error
%% object {name, message, stack}; it comes back as {error, Message}.
call(Peer, Method, Args) ->
    try ssb_peer:rpc_call(Peer, Method, <<"async">>, Args) of
        {ok, Body} ->
            case decode(Body) of
                {ok, #{~"name" := _, ~"message" := Msg, ~"stack" := _} = E}
                  when map_size(E) =:= 3 ->
                    {error, Msg};
                Decoded ->
                    Decoded
            end;
        Err ->
            {error, Err}
    catch
        exit:Reason -> {error, Reason}
    end.

%% A whole source stream, collected.  {ok, [DecodedJson]} | {error, Reason}.
%% Fine for git.repos and the like; a long stream wants open_source/4.
stream(Peer, Method, Args) ->
    try ssb_peer:rpc_stream_call(Peer, Method, Args) of
        {ok, Bodies} ->
            Items = [decode(B) || B <- Bodies],
            case [E || {error, _} = E <- Items] of
                []      -> {ok, [V || {ok, V} <- Items]};
                [E | _] -> E
            end;
        Err ->
            {error, Err}
    catch
        exit:Reason -> {error, Reason}
    end.

%% A source stream frame by frame: Fun(RawBody, Acc) for each item as it
%% arrives, so neither memory nor a total timeout grows with the stream.
%% {ok, Acc} | {error, Reason}.
stream_each(Peer, Method, Args, Fun, Acc0) ->
    case ssb_peer:open_source(Peer, Method, Args, self()) of
        {ok, Ref} -> drain(Ref, Fun, Acc0);
        Err       -> {error, Err}
    end.

drain(Ref, Fun, Acc) ->
    receive
        {stream_data, Ref, Body} -> drain(Ref, Fun, Fun(Body, Acc));
        {stream_done, Ref}       -> {ok, Acc}
    after ?STREAM_IDLE_MS ->
        {error, {stream_idle, ?STREAM_IDLE_MS}}
    end.

%% Store Bytes on the node through the blobs.add sink.  ok | {error, R}.
%% The sink ends with JSON `true`; anything else is the node refusing
%% (too big, or a hash mismatch) and is returned as the error.
add_blob(Peer, Bytes) ->
    try ssb_peer:open_sink(Peer, [~"blobs", ~"add"], [], self()) of
        {ok, ReqNo, Ref} ->
            [ssb_peer:send_sink_data(Peer, ReqNo, C) || C <- chunks(Bytes)],
            ssb_peer:send_sink_end(Peer, ReqNo),
            receive
                {rpc_reply, Ref, Body} ->
                    case decode(Body) of
                        {ok, true} -> ok;
                        {ok, #{~"message" := Msg}} -> {error, Msg};
                        Other -> {error, Other}
                    end
            after ?STREAM_IDLE_MS ->
                {error, {blobs_add_timeout, ?STREAM_IDLE_MS}}
            end;
        Err ->
            {error, Err}
    catch
        exit:Reason -> {error, Reason}
    end.

%% 64 KB frames, as ssb-client sends a file.
chunks(<<C:65536/binary, Rest/binary>>) -> [C | chunks(Rest)];
chunks(<<>>)                            -> [];
chunks(Last)                            -> [Last].

decode(Body) when is_binary(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, {bad_json, Body}}
    end;
decode(Other) ->
    {error, {unexpected_body, Other}}.

%%%===================================================================
%%% Bootstrap (from sbutt.escript)
%%%===================================================================

release_root() ->
    case os:getenv("SSB_HOME") of
        Home when is_list(Home), Home =/= "" ->
            Home;
        _ ->
            die("SSB_HOME is not set; run this through bin/git-ssb, "
                "or set it to the erlbutt release directory", [])
    end.

port() ->
    case os:getenv("SSB_PORT") of
        P when is_list(P), P =/= "" -> list_to_integer(P);
        _                           -> ?DEFAULT_PORT
    end.

%% The CURRENT release's app versions, at the front of the path: lib/
%% accumulates every version ever unpacked, and only releases/
%% start_erl.data says which one the node boots.  ssb_git itself is
%% skipped — the launcher already put the right one on the path, and a
%% copy in the release must not replace the module that is running.
add_release_paths(Root) ->
    case release_apps(Root) of
        {ok, Apps} ->
            [begin
                 code:add_patha(filename:join(Dir, "ebin")),
                 code:add_pathz(filename:join(Dir, "priv"))
             end || {App, AV} <- Apps,
                    App =/= ssb_git,
                    Dir <- [filename:join([Root, "lib", AV])],
                    filelib:is_dir(filename:join(Dir, "ebin")),
                    not owned_by_runtime(App, Root)];
        error ->
            [code:add_path(P)
             || P <- filelib:wildcard(filename:join(Root, "lib/*/ebin"))
                    ++ filelib:wildcard(filename:join(Root, "lib/*/priv")),
                not lists:prefix("ssb_git-",
                                 filename:basename(filename:dirname(P)))]
    end,
    case code:ensure_loaded(ssb_peer) of
        {module, _} -> ok;
        _           -> die("no erlbutt beams under ~s/lib", [Root])
    end.

owned_by_runtime(App, Root) ->
    case code:lib_dir(App) of
        {error, bad_name} -> false;
        LibDir ->
            RuntimeLib = filename:join(code:root_dir(), "lib"),
            filename:dirname(LibDir) =:= RuntimeLib
                andalso filename:absname(Root) =/= filename:absname(code:root_dir())
    end.

release_apps(Root) ->
    Rels = filename:join(Root, "releases"),
    try
        {ok, Data} = file:read_file(filename:join(Rels, "start_erl.data")),
        [_ErtsVsn, RelVsn] = string:lexemes(string:trim(Data), " "),
        [RelFile] = filelib:wildcard(filename:join([Rels, binary_to_list(RelVsn), "*.rel"])),
        {ok, [{release, _, _, Apps}]} = file:consult(RelFile),
        {ok, [{element(1, A),
               atom_to_list(element(1, A)) ++ "-" ++ element(2, A)} || A <- Apps]}
    catch _:_ ->
        error
    end.

%% Load the node's identity, never create one.
start_keys() ->
    application:set_env(ssb, mint_identity, false),
    Old = process_flag(trap_exit, true),
    Started = keys:start_link(),
    process_flag(trap_exit, Old),
    case Started of
        {ok, _} ->
            ok;
        {error, no_identity} ->
            die("no identity in ~s; is SSB_DATA right?",
                [config:ssb_repo_loc()]);
        {error, Reason} ->
            die("cannot load the identity in ~s: ~p",
                [config:ssb_repo_loc(), Reason])
    end.

die(Fmt, Args) ->
    io:format(standard_error, "ssb_git: " ++ Fmt ++ "~n", Args),
    erlang:halt(1).
