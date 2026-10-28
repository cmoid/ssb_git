%% SPDX-License-Identifier: GPL-2.0-only
%%
%% Copyright (C) 2026 Commonwealth of Scuttlebutt
%%
%% Entry point for both commands, started by bin/git-ssb as
%%
%%   erl -noshell -s ssb_git_cli start -extra <invoked-as> <args...>
%%
%% -extra rather than -run's own arguments: erl would read an argument such
%% as --mine as one of its own flags, and nothing after -extra is.
%%
%% One program, two names, chosen by the name it was run as — git's own
%% conventions supply both:
%%
%%   git-remote-ssb  git runs this itself for any ssb:// URL, and talks to
%%                   it over stdin/stdout (ssb_git_remote).  Never run by
%%                   hand.
%%   git-ssb         git runs `git-<name>` for `git <name>`, so this is
%%                   `git ssb ...`: the forge commands git has no word for.
%%
%% stdout belongs to git when running as the remote helper, so before
%% anything can log, logging is moved to stderr.
-module(ssb_git_cli).

-export([start/0, main/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

start() ->
    main(init:get_plain_arguments()).

main([Invoked | Args]) ->
    log_to_stderr(),
    Code = try dispatch(filename:basename(Invoked), Args)
           catch Class:Reason:Stack ->
                   io:format(standard_error, "ssb_git: ~p:~p~n~p~n",
                             [Class, Reason, Stack]),
                   1
           end,
    erlang:halt(Code);
main([]) ->
    usage(),
    erlang:halt(2).

dispatch("git-remote-ssb", Args) -> ssb_git_remote:main(Args);
dispatch(_GitSsb, Args)          -> git_ssb(Args).

%%%===================================================================
%%% git ssb ...
%%%===================================================================

git_ssb(["repos" | Rest]) ->
    case repos_opts(Rest) of
        {ok, Opts} -> cmd_repos(Opts);
        error      -> usage(), 2
    end;
git_ssb(["create" | Rest]) ->
    case create_opts(Rest) of
        {ok, Name, Remote} -> cmd_create(Name, Remote);
        error              -> usage(), 2
    end;
git_ssb(["dump", File]) ->
    cmd_dump(File);
git_ssb(["version"]) ->
    _ = application:load(ssb_git),
    {ok, Vsn} = application:get_key(ssb_git, vsn),
    io:format("git-ssb (ssb_git) ~s~n", [Vsn]),
    0;
git_ssb(["help"]) -> usage(), 0;
git_ssb([])       -> usage(), 0;
git_ssb(_)        -> usage(), 2.

repos_opts([])                -> {ok, #{}};
repos_opts(["--author", Id])  -> {ok, #{author => list_to_binary(Id)}};
repos_opts(["--mine"])        -> {ok, #{author => mine}};
repos_opts(_)                 -> error.

create_opts([Name])                   -> {ok, Name, none};
create_opts([Name, "--remote", Remote]) -> {ok, Name, Remote};
create_opts(["--remote", Remote, Name]) -> {ok, Name, Remote};
create_opts(_)                        -> error.

%% Publish a git-repo message — {type: git-repo, name} — and print its
%% URL.  The message id is the repo: there is nothing else to create, and
%% the first push makes its branches.
%%
%% Publishing cannot be undone, so everything that could make the command
%% fail is checked first: a remote is only added inside a git repository,
%% and only under a name not already taken.
cmd_create(Name, Remote) ->
    case {Name, check_remote(Remote)} of
        {"", _} ->
            io:format(standard_error, "git ssb create: the name is empty~n", []),
            2;
        {_, {error, Why}} ->
            io:format(standard_error, "git ssb create: ~s~n", [Why]),
            1;
        {_, ok} ->
            {ok, Peer} = ssb_git_client:connect(),
            Content = {[{~"type", ~"git-repo"},
                        {~"name", unicode:characters_to_binary(Name)}]},
            case ssb_git_client:call(Peer, [~"publish"], [Content]) of
                {ok, #{~"key" := Id}} ->
                    Url = <<"ssb://", Id/binary>>,
                    io:format("~s~n", [Url]),
                    add_remote(Remote, Url);
                {error, Reason} ->
                    io:format(standard_error, "git ssb create: ~p~n", [Reason]),
                    1
            end
    end.

check_remote(none) ->
    ok;
check_remote(Remote) ->
    case ssb_git_local:git_quiet(["rev-parse", "--git-dir"]) of
        {0, _} ->
            case ssb_git_local:git_quiet(["remote", "get-url", Remote]) of
                {0, _} -> {error, io_lib:format("there is already a remote ~s", [Remote])};
                _      -> ok
            end;
        _ ->
            {error, "--remote needs to be run inside a git repository"}
    end.

add_remote(none, _Url) ->
    0;
add_remote(Remote, Url) ->
    case ssb_git_local:git(["remote", "add", Remote, Url]) of
        {0, _} ->
            io:format(standard_error, "added remote ~s~n", [Remote]),
            0;
        {S, _} ->
            %% the repo exists now whatever happens here; say how to finish
            io:format(standard_error,
                      "git ssb create: the repo was created, but git remote add "
                      "exited ~p; run: git remote add ~s ~s~n", [S, Remote, Url]),
            1
    end.

cmd_repos(Opts) ->
    {ok, Peer} = ssb_git_client:connect(),
    Args = case maps:get(author, Opts, undefined) of
               undefined -> [];
               mine      -> [{[{~"author", keys:pub_key_disp()}]}];
               Author    -> [{[{~"author", Author}]}]
           end,
    case ssb_git_client:stream(Peer, [~"git", ~"repos"], Args) of
        {ok, Repos} ->
            [io:format("ssb://~s  ~s~n",
                       [maps:get(~"id", R), maps:get(~"name", R, ~"")])
             || R <- Repos],
            0;
        {error, Reason} ->
            io:format(standard_error, "git ssb repos: ~p~n", [Reason]),
            1
    end.

%% Every git-repo and git-update message the node holds, one stored message
%% per line, as the node sends them — the input to tools/fold-diff.
%% messagesByType is silkpurse's, which every erlbutt release carries.
cmd_dump(File) ->
    {ok, Peer} = ssb_git_client:connect(),
    {ok, Fd} = file:open(File, [write, raw, binary, delayed_write]),
    Write = fun(Body, N) -> ok = file:write(Fd, [Body, $\n]), N + 1 end,
    Result = lists:foldl(
               fun(_Type, {error, _} = E) -> E;
                  (Type, {ok, N}) ->
                       ssb_git_client:stream_each(
                         Peer, [~"messagesByType"], [{[{~"type", Type}]}],
                         Write, N)
               end, {ok, 0}, [~"git-repo", ~"git-update"]),
    ok = file:close(Fd),
    case Result of
        {ok, N} ->
            io:format(standard_error, "~p messages written to ~s~n", [N, File]),
            0;
        {error, Reason} ->
            io:format(standard_error, "git ssb dump: ~p~n", [Reason]),
            1
    end.

usage() ->
    io:format(standard_error,
              "usage: git ssb <command>~n~n"
              "  create <name> [--remote <remote>]  publish a new repo; print its URL,~n"
              "                                     and add it as a remote here~n"
              "  repos [--mine | --author <feed>]   list known repos~n"
              "  dump <file>                        every git message, for tools/fold-diff~n"
              "  version~n"
              "  help~n~n"
              "Clone, fetch and push use ordinary git with an ssb:// URL;~n"
              "git runs git-remote-ssb for those itself.~n", []).

%%%===================================================================
%%% Internal
%%%===================================================================

log_to_stderr() ->
    _ = logger:remove_handler(default),
    ok = logger:add_handler(default, logger_std_h,
                            #{config => #{type => standard_error}}),
    ok = logger:set_primary_config(level, error).

%%%===================================================================
%%% Tests
%%%===================================================================
-ifdef(TEST).

create_opts_test_() ->
    [?_assertEqual({ok, "foo", none}, create_opts(["foo"])),
     ?_assertEqual({ok, "foo", "origin"}, create_opts(["foo", "--remote", "origin"])),
     ?_assertEqual({ok, "foo", "origin"}, create_opts(["--remote", "origin", "foo"])),
     ?_assertEqual(error, create_opts([])),
     ?_assertEqual(error, create_opts(["foo", "bar"])),
     ?_assertEqual(error, create_opts(["foo", "--remote"]))].

-endif.
