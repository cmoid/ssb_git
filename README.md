ssb_git
=======

Git over Secure Scuttlebutt, as a plugin for
[erlbutt](https://github.com/cmoid/erlbutt).

A repository lives on SSB as signed messages and content-addressed blobs:
the objects in git packfiles stored as blobs, the branches in `git-update`
messages that say what each push produced. There is no server and no
upstream authority. Anyone can push to a repo, every push is published in
the pusher's own feed, and divergent pushes show up as conflict branches
instead of being rejected.

The message format is the one git-ssb used, so the repos already on the
network can be cloned, and clients that speak git-ssb can read what this
publishes. git itself is unchanged: it reaches SSB through its standard
remote-helper mechanism, so `clone`, `fetch` and `push` work as with any
other remote, from the command line, Emacs's built-in VC, or any other
git front end.

## Using it

A repo's URL is `ssb://` followed by the id of its `git-repo` message:

```
git clone ssb://%n92DiQh7ietE+R+X/I403LQoyf2DtR3WQfCkDKlheQU=.sha256 <foo>
cd <foo>
# ... edit, commit ...
git push
```

Give `git clone` a directory. Most repo ids contain a `/`, and git would
name the clone after whatever follows the last one.

`ssb:%…` and the percent-escaped form `ssb://%25…` that git-ssb-web
printed in its links work too.

To put an existing repository on SSB:

```
cd myproject
git ssb create myproject --remote origin
git push origin master
```

`create` publishes the new repo from your feed and prints its URL; with
`--remote` it also adds that URL as a remote, refusing before anything is
published if it is not in a git repository or the remote name is taken.
The repo is just that message. Its branches arrive with the first push.

Fetch and push go through the local erlbutt node, never the network
directly. A clone is read from the packs the node already holds; any it
lacks are asked of its peers, and the fetch waits for them for a time. A
push stores its pack on the node, announces it to peers, and publishes the
update from your feed.

Commands git has no word for are under `git ssb`:

```
git ssb create <name> [--remote <remote>]
                                publish a new repo and print its URL
git ssb repos                   every repo the node knows, oldest first
git ssb repos --mine            the repos you created
git ssb repos --author <feed>   the repos one feed created
git ssb dump <file>             every git-repo and git-update message, one per line
git ssb version
git ssb help
```

## In Emacs

`elisp/ssb-git.el` is the forge: the repos the node knows, a repo's
branches and pushes, and its issues and pull requests. It runs on
[maxbutt](https://github.com/cmoid/maxbutt), using its connection to the
node, its feed and thread views, and Distel, so maxbutt has to be set up
first — a maxbutt recent enough to carry non-ASCII text correctly (its
erlext UTF-8 fix, October 2026); with an older one, titles and comments
outside ASCII are garbled in both directions.

```elisp
(add-to-list 'load-path "<release>/plugins/ssb_git/elisp")
(require 'ssb-git)
```

| buffer | opened by | keys |
|---|---|---|
| repos | `M-x ssb-git-repos` (`C-u` for yours) | `RET` open · `m` yours/all · `g` refresh |
| a repo | `RET` on a repo, or `M-x ssb-git-repo` | `i` issues · `P` pull requests · `N` new issue · `R` new pull request · `w` copy URL · `C` clone · `RET`/`t` a push as a thread · `f` author's feed |
| issues, pull requests | `i`, `P` | `RET` open · `s` open/closed/all · `N` new |
| an issue or pull request | `RET` on one, or `M-x ssb-git-issue` | `r` comment · `x` close/reopen · `o` check out the pull request · `t` thread view · `f` author's feed |

An issue buffer shows the text, every change anyone has published to its
state (marked when it does not count; see below), and its comments.
Checking out a pull request fetches its branch from the head repo into a
clone of yours as `pr/<id>` and switches to it. Compose buffers send with
`C-c C-c` and cancel with `C-c C-k`.

## How it works

```
git ──────────stdin/stdout──► git-remote-ssb ──SHS + muxrpc──► ssb_git in erlbutt
                              (git starts it)    (as owner)     (views + RPCs)
```

Three parts, one OTP application:

| part | what it does | source |
|---|---|---|
| the plugin | runs inside the node: views over the message store and the `git.*` RPCs | `ssb_git_repos`, `ssb_git_refs`, `ssb_git_fold` |
| `git-remote-ssb` | started **by git** for any `ssb://` URL; does fetch and push | `ssb_git_remote`, `ssb_git_push`, `ssb_git_local` |
| `git ssb …` | the commands above | `ssb_git_cli` |

The two commands are one program, `bin/git-ssb`, that picks its behaviour
from the name it was run as (`bin/git-remote-ssb` is a symlink to it). It
is a shell launcher that runs the erlbutt release's own `erl` with the
release's beams, so the client code is always the node's version, and the
node's identity and data are found the way the node finds them. It
connects to the node over SHS as the node's owner.

**Branches are a fold.** A repo's refs are computed from all of its
`git-update` messages, a faithful port of git-ssb's merge (ssb-git 0.5.0),
quirks included. Updates link to the updates they were pushed on top of,
forming a DAG. Within one feed the later update wins. Updates from
different feeds that do not see each other are concurrent: both values
survive, as conflict branches named `refs/heads/%<update id>/<branch>`. A
push on top of them resolves the conflict, and keeps the other side as an
explicit branch so that no commit is lost.

**Issues and pull requests** are messages filed against the repo
(`issue`, `pull-request`), their comments ordinary posts in their thread.
Whether one is open is decided by `issue-edit` messages and by pushes. A
push closes an issue when a commit it adds to the HEAD branch says
`fixes %<issue id>` (or close/closes/closed, fix/fixed), and closes a pull
request as merged when the pull request's branch tip is among them.
Anyone can publish a close; a reader decides whose to honour. ssb_git
counts the issue's author and the repo's owner, and shows the rest as not
counted.

**Fetch** asks the node for every pack the repo's updates name, skips
those already in the clone (recorded in `.git/ssb/`), and feeds the rest
to `git index-pack`. index-pack recomputes every object's hash, so a pack
is trusted exactly as far as git trusts any pack; the published `.idx`
files are not read.

**Push** packs what the repo does not yet have (non-thin, so a reader
never needs a base it lacks), stores the pack and its index as blobs, and
publishes one `git-update` for the whole push, linked to every current
head of the repo. A force-push is published like any other. An update
must fit in SSB's 8 KB message limit, so a large push lists only its
newest commits, counting the rest in `commits_more`.

**Large packs.** A blob may be at most 5 MB, so a pack or index over that
is stored in 4 MB pieces:

```json
"packs": [{"link": "&<piece 1>", "size": 4194304, "chunks": ["&<piece 2>", "&<piece 3>"]}]
```

`link` and `size` describe the first piece, and the pack is the pieces
joined in order. This is the one extension to git-ssb's format. git-ssb
itself would read the first piece as a short pack and fail at index-pack.
Only initial imports of big histories should ever need it.

## RPC methods

All are owner-only.

| method | type | returns |
|---|---|---|
| `git.repos({author?})` | source | repos, oldest first: `{id, author, name?, upstream?, ts}` |
| `git.refs({repo})` | async | `{head, refs: [{name, hash}]}`, a fork inheriting its upstream's refs |
| `git.packs({repo})` | async | `[{update, pack, idx?, size?, chunks?}]`, oldest first |
| `git.updates({repo})` | async | `[{key, links, refs}]`, the repo's update graph |
| `git.issues({repo, kind?, state?})` | async | issues and/or pull requests, newest first; `state` open (default), closed or all |
| `git.issue({id})` | async | one, with `open`, `merged` and every change to it, each marked `counted` |

## Installing

erlbutt's packages include ssb_git: built in an erlbutt tree with this
repository checked out beside it, `make prodpkg` (or `devpkg`, `rel`)
puts it in `<release>/plugins/ssb_git/`, and the node starts it at boot.
To leave it out, put `{plugins, []}.` in `<data>/ssb.cfg`.

To add it to a node whose package did not include it, build it here and
copy `_build/default/lib/ssb_git/ebin` and `bin/` to
`<data>/plugins/ssb_git/`, then restart the node. A copy there also
replaces one the package shipped, and survives upgrades.

The first time the plugin starts, its views index every git message in
the node's store, in the background, while the node carries on.

Then put the two commands on your PATH:

```
ln -s <release>/plugins/ssb_git/bin/git-ssb        ~/.local/bin/git-ssb
ln -s <release>/plugins/ssb_git/bin/git-remote-ssb ~/.local/bin/git-remote-ssb
```

### Environment

| variable | meaning |
|---|---|
| `SSB_HOME` | the erlbutt release to use; by default the one the launcher is installed in, else the one `sbutt` on PATH belongs to |
| `SSB_DATA` | the node's data directory, as for the node |
| `SSB_PORT` | the node's port (default 8008) |
| `SSB_GIT_BLOB_WAIT` | seconds a fetch waits for packs the node has to get from peers (default 60) |
| `GIT_TRANSPORT_HELPER_DEBUG=1` | git's own: shows the conversation between git and the helper |

## Limitations

- Private repos (git-ssb's `recps`) are not supported.
- Repo names come only from the `git-repo` message; renames published
  later as `about` messages are not shown.
- 22 of the earliest updates on the network stored each object as its
  own blob rather than in a pack; they are not read.
- A plugin cannot be unloaded from a running node; removing it takes a
  restart, and its tables stay in the store.

## Development

```
make checkout      # build against ~/code/erlbutt, or ERLBUTT=<path>
make               # compile
make test          # eunit
make elisp         # byte-compile elisp/ as a check (needs maxbutt)
```

Without `make checkout`, rebar3 fetches erlbutt's `apps/ssb` from GitHub.
Only `ssb` itself is fetched, not its dependencies, which nothing here
needs to compile; hence the one warning about `ranch_protocol`.

The plugin is built against erlbutt's plugin API version and refuses to
start on a node with a different one, saying which. Build it against the
erlbutt it will run in.

### Checking the fold against git-ssb

`tools/fold-diff` runs git-ssb's own merge over every repo a node holds
and compares the result with `ssb_git_fold`:

```
git ssb dump /tmp/git.ndjson
(cd tools/fold-diff && npm install)     # ssb-git 0.5.0 + kvgraph 0.1.0
node tools/fold-diff/reference.js /tmp/git.ndjson > /tmp/ref.json
tools/fold-diff/fold-diff.escript /tmp/git.ndjson /tmp/ref.json
```

`fold-diff.escript <dump> --self` folds everything without the reference,
as a smoke test.

The design, and the reasoning behind it, is in erlbutt's
[`doc/research/git-over-ssb.md`](https://github.com/cmoid/erlbutt/blob/main/doc/research/git-over-ssb.md).

## License

GPL-2.0-only, as erlbutt, whose `ssb` application this links against.
Copyright © 2026 Commonwealth of Scuttlebutt.
