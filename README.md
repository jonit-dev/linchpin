# linchpin

[![verify](https://github.com/jonit-dev/linchpin/actions/workflows/verify.yml/badge.svg)](https://github.com/jonit-dev/linchpin/actions/workflows/verify.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![codex plugin](https://img.shields.io/badge/codex-plugin-black.svg)](https://developers.openai.com/codex/)
[![version](https://img.shields.io/badge/version-0.5.0-informational.svg)](.codex-plugin/plugin.json)

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

Codex only. Claude Code is not supported.

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
worker = ""              # "" = shipped pin; luna | sol | terra
worker_effort = ""       # "" = shipped pin; low | medium | high | max
reviewer = ""            # "" = shipped pin; luna | sol | terra
reviewer_effort = ""     # "" = shipped pin; low | medium | high | max
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

Preflight checks both the worker and the reviewer model against your local model
cache before creating any branch. Otherwise a missing reviewer model would blow
up at the first review, after the run had already spent all its worker time.

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
Worktrees and merged lane branches are cleaned up at the end of the run. A lane
that finished `PARTIAL` or `BLOCKED` keeps its worktree and branch on purpose;
the final report names each one and the command that resumes it.

## Runtime

Model pins and delegation rules live only in `references/runtime.md`. Luna runs
only as a `codex exec` subprocess, never as a native subagent. Sol handles the
manager and read-only reviewer roles. When a lane needs repair, linchpin changes
the specification or the handoff, not the model tier.

## Install-swap

This repo does not touch anything under your Codex, Claude or Hermes
directories. Swapping out an incumbent install is a manual step you confirm
yourself. Read [docs/migration-swap.md](docs/migration-swap.md) and run the
read-only `scripts/migration-swap.sh --dry-run` before any backup, equality
check or removal.

## Not in v1

Claude Code support, patch delivery, cross-lane dependency ordering, and the
optional goal loop.
