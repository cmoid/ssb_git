// SPDX-License-Identifier: GPL-2.0-only
//
// Copyright (C) 2026 Commonwealth of Scuttlebutt
//
// The reference side of fold-diff: git-ssb's own ref fold, ssb-git 0.5.0's
// merge driven by kvgraph's reduceRight exactly as ssb-git-repo drove it,
// over every repo in a `git ssb dump`.
//
//   node reference.js DUMP.ndjson > reference.json
//
// Output: {repoId: {head, refs: [[name, hash], ...]}}, refs in the order
// Repo.refs() would emit them (own, then inherited from upstream, unique by
// name).
//
// The order objects are added in is part of the input — merge.js depends
// on it — so it is spelled out here and must match fold_diff.erl: the repo
// message first, then its updates newest first (git-ssb synced with
// reverse: true), ties broken by key.

var fs = require('fs')
var KVGraph = require('kvgraph')
var merge = require('ssb-git/merge')

var lines = fs.readFileSync(process.argv[2], 'utf8').split('\n')
var repos = {}, updates = {}

lines.forEach(function (line) {
  if (!line) return
  var msg = JSON.parse(line)
  var c = msg.value.content
  if (!c || typeof c !== 'object') return          // private: not indexed
  if (c.type === 'git-repo') repos[msg.key] = msg
  else if (c.type === 'git-update' && typeof c.repo === 'string')
    (updates[c.repo] = updates[c.repo] || []).push(msg)
})

function ts(msg) {
  return typeof msg.value.timestamp === 'number' ? msg.value.timestamp : 0
}

function newestFirst(a, b) {
  return ts(b) - ts(a) || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)
}

var own = {}
function fold(id) {
  if (own[id]) return own[id]
  var graph = KVGraph('key')
  graph.add(repos[id])
  ;(updates[id] || []).slice().sort(newestFirst).forEach(function (u) {
    graph.add(u)
  })
  var state = graph.reduceRight(merge)
  return own[id] = {head: state.head, refs: state.refs.map(function (r) {
    return [r.name, r.hash]
  })}
}

// Repo.refs(): own refs, then the upstream's (recursively), unique by name.
function refs(id, seen) {
  var r = fold(id).refs
  var up = repos[id].value.content.upstream
  if (typeof up === 'string' && repos[up] && !seen[up]) {
    seen[up] = true
    r = r.concat(refs(up, seen))
  }
  return r
}

function unique(pairs) {
  var seen = {}
  return pairs.filter(function (p) {
    if (seen[p[0]]) return false
    return seen[p[0]] = true
  })
}

var out = {}
Object.keys(repos).sort().forEach(function (id) {
  var seen = {}
  seen[id] = true
  out[id] = {head: fold(id).head, refs: unique(refs(id, seen))}
})
process.stdout.write(JSON.stringify(out) + '\n')
