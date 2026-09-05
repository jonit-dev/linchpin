# linchpin

[![verify](https://github.com/jonit-dev/linchpin/actions/workflows/verify.yml/badge.svg)](https://github.com/jonit-dev/linchpin/actions/workflows/verify.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![codex plugin](https://img.shields.io/badge/codex-plugin-black.svg)](https://developers.openai.com/codex/)
[![version](https://img.shields.io/badge/version-0.10.0-informational.svg)](.codex-plugin/plugin.json)

A Codex plugin that takes your PRDs and builds them.

Hand it a batch. It splits the work into lanes, runs each lane in its own git
worktree, has a separate read-only reviewer check the result, and reports what
shipped and what did not. Your Codex session stays in charge as the
manager; the implementation happens in `codex exec` subprocesses.

The default split is the whole idea:

| Step | Who | Effort |
|---|---|---|
| Write the PRD | you, with whatever model you like (I use Opus 5) | — |
| Implement the lane | Luna | `max` |
| Review the lane | Sol, read-only, fresh process | `high` |

Luna at max effort does the building. Sol at high effort checks it, in a
separate process that cannot write. The model that wrote the code is never the
model that approves it, and you are not paying manager-tier rates for the part
that is mostly typing.

Two providers, per role. The shipped pins are Codex, so a zero-config run is
exactly the run above. Name a Claude alias for a role and that role becomes a
`claude -p` process instead — you can put a Claude Code worker beside a Codex
reviewer in the same run, and each is verified before a branch exists.

## Install

`codex plugin add` installs from a marketplace, so you register this repo as a
marketplace first:

```sh
codex plugin marketplace add jonit-dev/linchpin --ref main
codex plugin add linchpin@linchpin
```

Then start a fresh Codex session. Type `$linchpin` and describe what you want,
or call `$prd-creator` and `$prd-swarm-coordinator` directly if you already know
which one you need. `$linchpin` just routes; it is not a prerequisite.

To install from a local checkout, pass the checkout path instead of the repo
name. The path needs `.agents/plugins/marketplace.json` in it, which this repo
has.

## Using it

It pays off most with a batch. One PRD works and takes the same path, but a
folder of them is where the parallel lanes earn their keep: hand it everything
you queued up and walk away.

```
$linchpin run docs/PRDs/PRD-007.md docs/PRDs/PRD-008.md
```

Point it at a directory and it takes every PRD in there. Plain English around
the paths is fine, and an `@Linchpin` mention works the same as `$linchpin`:

```
/goal execute docs/PRDs/active/client-e2e-tests these PRDs with @Linchpin
```

"start", "begin", "launch" and "resume" mean execute. Naming files you already
wrote never makes it write a new PRD over them.

When you ask for something new, it scores the request first. Trivial changes get
refused and offered as a direct edit instead of a five-lane pipeline. Anything
bigger goes to the creator, which stops and waits for you to confirm the draft
before a single branch is created.

Old PRDs run as written. If a PRD predates the file-list format, linchpin reads
the paths out of your prose. If it never declared a section, that section is
reported missing rather than invented. Delivery is gated on the checks your PRD
actually asked for, not on checks linchpin wishes it had. One bad path asks about
that path and runs the rest of the batch.

`sh scripts/linchpin.sh help` lists the subcommands the skills use.

## Upgrading an old PRD to the contract

Only needed if you want the standard format. Execution does not require it.

```sh
sh scripts/linchpin.sh migrate docs/PRDs/PRD-007-example.md
```

This reads the original and never writes to it. Output goes to
`PRD-007-example.v1.md` with headings renamed, prose `**Files:**` paragraphs
converted to parseable `Files (N)` lists, and missing sections scaffolded. You
get one of two results:

- `MIGRATED` — the file carries `prd_contract: v1` and is ready to run.
- `MIGRATION-INCOMPLETE` — every remaining gap is listed, including each
  `MIGRATION-TODO` line. Gaps that need real evidence, like a gate's exact
  command or a caller's `file:line`, are yours to fill in. A parser cannot guess
  them.

`sh scripts/linchpin.sh contract <prd>` reports every problem in one pass.

## Configuration

One optional file, `.linchpin.toml`, in the repo you are working on. Skip it and
you get the defaults below:

```toml
execution = "auto"       # auto | parallel | sequential
delivery = "pr"          # pr | branch
base = "auto"            # auto = repository default branch
review = true
max_lanes = 4
prd_floor = 3
worker = ""              # "" = shipped pin; an alias from the table below
worker_effort = ""       # "" = shipped pin; the resolved provider's domain
reviewer = ""            # "" = shipped pin; an alias from the table below
reviewer_effort = ""     # "" = shipped pin; the resolved provider's domain
```

`sh scripts/linchpin.sh config .` prints what actually resolved, including which
defaults are in play. A bad key or value fails there, before the run starts,
instead of once per lane in the middle of one.

Models and effort are per-repo so you never have to edit
`references/runtime.md`, which ships inside the plugin and gets overwritten when
you upgrade.

Pick models by alias, never by raw slug. `worker = "gpt-5.6-luna"` is rejected
the same as a typo would be, because a slug written into a config file goes stale
the moment the model class moves. The alias table in `references/runtime.md` is
the only place a slug appears.

The provider travels with the alias — there is no provider key to keep in sync:

| Provider | Aliases | Effort domain |
|---|---|---|
| Codex | `luna`, `sol`, `terra`, `astra` | `low` `medium` `high` `max` |
| Claude Code | `opus-5`, `opus-4.8`, `sonnet-5`, `haiku-4.5`, `fable-5.1` | `low` `medium` `high` `xhigh` `max` |

Effort is checked against the domain of the provider that role resolved to, so
`xhigh` is accepted for a Claude role and refused for a Codex one.

**You do not have to edit the file, or run anything.** Say it to `$linchpin`
along with whatever you actually wanted done:

```text
$linchpin use Astra medium as reviewer and Opus 5 medium as executor, then run docs/PRDs/PRD-007.md
```

The router resolves the assignment, writes the two keys, announces what it
resolved, and then runs the PRD. Naming models does not change the route — that
is still an execute request.

```text
ASSIGN role=reviewer alias=astra effort=medium provider=codex model=gpt-6-astra
ASSIGN role=worker alias=opus-5 effort=medium provider=claude model=claude-opus-5
```

`executor`, `worker`, `implementer` and `builder` all name the worker;
`reviewer`, `review` and `critic` name the reviewer.

If you want it in a script instead, that same step is one command. Run it from
the repo and it writes `./.linchpin.toml`; drop `--write` to see what it
resolved without changing anything:

```sh
sh scripts/linchpin.sh assign "use Astra medium as reviewer and Opus 5 medium as executor" --write
```

**A model that is not in the table is not refused — it is verified.** `assign`
looks an unknown name up live (the Codex capability cache, or one trivial Claude
Code request) and, when it comes back, records it in `.linchpin-models.toml` in
your repo so it is still an alias everywhere downstream. A name that verifies on
neither provider is refused *by name*: `ASSIGN-UNRESOLVED nimbus-9` and a
non-zero exit, never a quiet substitution.

Preflight checks every role before creating any branch — a Codex role against
your local model cache, a Claude role with one live `--max-turns 1` probe per
distinct model. Otherwise a missing reviewer model would blow up at the first
review, after the run had already spent all its worker time. A failure is a
refusal, not a downgrade.

None of these settings weaken review or gate evidence. Those come from the PRD.

## What a run leaves behind

Runs write ledgers, briefs and lane logs to `.linchpin/`, and worktrees to
`.worktrees/`, both in the target repo. Neither should show up in your
`git status`:

```sh
sh scripts/linchpin.sh workspace .
```

The coordinator runs this before its first write. It creates `.linchpin/` and
adds both paths to `.git/info/exclude` unless the repo already ignores them.
`.git/info/exclude` rather than `.gitignore` is deliberate: ignoring linchpin's
scratch output should not leave a modified tracked file behind or sweep into a
lane commit. If you want the ignore rule committed for your team, add
`.linchpin/` to `.gitignore` yourself.

Keep `.linchpin/` to resume or audit a run, delete it when you are done.
Worktrees and lane branches are cleaned up at the end of every batch:

```sh
sh scripts/linchpin.sh prune .linchpin/run-1738000000.md
```

A delivered lane loses its worktree and its branch. Everything else is kept and
named: a lane that finished `PARTIAL` or `BLOCKED`, a worktree with uncommitted
work in it, and a branch whose commits are neither in your base branch nor on
the remote. A lane that shipped as a squashed PR counts as merged — `git branch
-d` does not know that, which is why lane branches pile up when they are deleted
by hand. Add `--dry-run` to see the list before anything is removed.

## Checking what a run actually delivered

The run ledger in `.linchpin/` is not prose the manager typed at the end. Every
row is written through `scripts/linchpin.sh lane`, which refuses a state it does
not recognize, a `DELIVERED` row missing its commit, gate evidence, or review,
and — the one that matters — a commit sha that does not resolve in your
repository. A lane cannot be recorded as shipped against a commit nobody made.

Read it back with a command instead of trusting a summary:

```sh
sh scripts/linchpin.sh status .linchpin/run-1738000000.md
```

```text
DELIVERED(pr) lane=lane-1 prd=docs/PRDs/PRD-007.md branch=linchpin/lane-1 commit=a1b2c3d gates=.linchpin/gates-1.md review=approve
PARTIAL lane=lane-2 prd=docs/PRDs/PRD-008.md branch=linchpin/lane-2
RUN-STATUS delivered=1 partial=1 blocked=0 pending=0 running=0 unrecorded=0
```

It exits `0` only when every lane is delivered, `1` while any lane is still
open, and `2` when the only unfinished lanes are blocked. That makes "is this
run done?" a question with an exit code rather than an opinion, which is what
you want when the answer arrives after you walked away.

## Runtime

Model pins and delegation rules live only in `references/runtime.md`. Luna runs
only as a `codex exec` subprocess, never as a native subagent. Sol handles the
manager and read-only reviewer roles. When a lane needs repair, linchpin changes
the specification or the handoff, not the model tier.

A worker runs with `--sandbox danger-full-access`, because a lane is a git
worktree and a commit and codex's default sandbox permits neither: a worktree
keeps its metadata in the parent repository, outside the one directory that
sandbox makes writable, so the commit fails with `Read-only file system` after
all the worker time is spent. What bounds a worker is its own worktree, its own
branch, the file list in its brief, and a reviewer that runs `--sandbox
read-only` and cannot edit what it judges. `references/runtime.md` records the
reproduction.

## Install-swap

This repo does not touch anything under your Codex, Claude or Hermes
directories. Swapping out an incumbent install is a manual step you confirm
yourself. Read [docs/migration-swap.md](docs/migration-swap.md) and run the
read-only `scripts/migration-swap.sh --dry-run` before any backup, equality
check or removal.

## Not in v1

Patch delivery, cross-lane dependency ordering, and the optional goal loop.
